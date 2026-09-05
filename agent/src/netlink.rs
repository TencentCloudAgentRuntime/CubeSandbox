// Copyright (c) 2021 Kata Maintainers
//
// SPDX-License-Identifier: Apache-2.0
//

use anyhow::{anyhow, Context, Result};
use futures::{future, StreamExt, TryStreamExt};
use ipnetwork::{IpNetwork, Ipv4Network, Ipv6Network};
use netlink_packet_route::address::{AddressAttribute, AddressMessage};
use netlink_packet_route::link::{LinkAttribute, LinkMessage};
use netlink_packet_route::neighbour::{
    self, NeighbourAddress, NeighbourAttribute, NeighbourFlag, NeighbourState,
};
use netlink_packet_route::route::{
    RouteAddress, RouteAttribute, RouteFlag, RouteHeader, RouteMessage, RouteProtocol, RouteScope,
    RouteType,
};
use netlink_packet_route::AddressFamily;
use protocols::types::{ARPNeighbor, IPAddress, IPFamily, Interface, Route};
use rtnetlink::{new_connection, IpVersion};
use std::convert::{TryFrom, TryInto};
use std::fmt;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::ops::Deref;
use std::str::{self, FromStr};
// Convenience macro to obtain the scope logger
macro_rules! sl {
    () => {
        slog_scope::logger().new(o!("subsystem" => "netlink"))
    };
}

const ALL_RULE_FLAGS: [NeighbourFlag; 8] = [
    NeighbourFlag::Use,
    NeighbourFlag::Own,
    NeighbourFlag::Controller,
    NeighbourFlag::Proxy,
    NeighbourFlag::ExtLearned,
    NeighbourFlag::Offloaded,
    NeighbourFlag::Sticky,
    NeighbourFlag::Router,
];

#[derive(Debug, Clone, PartialEq, Eq)]
struct ConnectedRouteIdentity {
    family: AddressFamily,
    destination: IpNetwork,
    preferred_source: IpAddr,
    output_interface: u32,
}

fn connected_route_identity(
    route: &Route,
    output_interface: u32,
) -> Option<ConnectedRouteIdentity> {
    if !route.gateway.is_empty() || route.dest.is_empty() || route.source.is_empty() || route.onlink
    {
        return None;
    }

    let destination = IpNetwork::from_str(&route.dest).ok()?;
    let source = IpNetwork::from_str(&route.source).ok()?;
    let source_is_host = match source {
        IpNetwork::V4(network) => network.prefix() == 32,
        IpNetwork::V6(network) => network.prefix() == 128,
    };
    let expected_scope = if destination.is_ipv4() {
        RouteScope::Link
    } else {
        RouteScope::Universe
    };
    if !source_is_host
        || !destination.contains(source.ip())
        || destination.is_ipv4() != source.is_ipv4()
        || (route.family() == IPFamily::v6) != destination.is_ipv6()
        || destination.prefix() == 0
        || route.scope != u8::from(expected_scope) as u32
    {
        return None;
    }

    Some(ConnectedRouteIdentity {
        family: if destination.is_ipv4() {
            AddressFamily::Inet
        } else {
            AddressFamily::Inet6
        },
        destination,
        preferred_source: source.ip(),
        output_interface,
    })
}

fn route_table(message: &RouteMessage) -> u32 {
    message
        .attributes
        .iter()
        .find_map(|attribute| match attribute {
            RouteAttribute::Table(table) => Some(*table),
            _ => None,
        })
        .unwrap_or(message.header.table as u32)
}

/// Match the exact kernel-created route which address assignment installs.
/// IPv4 exports its source as RTA_PREFSRC. Linux IPv6 connected routes often
/// omit RTA_PREFSRC, so the caller additionally verifies that the requested
/// source address is assigned to the same output interface.
fn matches_connected_route(message: &RouteMessage, expected: &ConnectedRouteIdentity) -> bool {
    let expected_scope = match expected.family {
        AddressFamily::Inet => RouteScope::Link,
        AddressFamily::Inet6 => RouteScope::Universe,
        _ => return false,
    };
    if message.header.address_family != expected.family
        || message.header.destination_prefix_length != expected.destination.prefix()
        || message.header.source_prefix_length != 0
        || route_table(message) != RouteHeader::RT_TABLE_MAIN as u32
        || message.header.protocol != RouteProtocol::Kernel
        || message.header.scope != expected_scope
        || message.header.kind != RouteType::Unicast
        || message.header.flags.contains(&RouteFlag::Onlink)
    {
        return false;
    }

    let mut destination = None;
    let mut preferred_source = None;
    let mut output_interface = None;
    for attribute in &message.attributes {
        match attribute {
            RouteAttribute::Destination(address) => {
                let address = match parse_route_addr(address) {
                    Ok(address) => address,
                    Err(_) => return false,
                };
                if destination.replace(address).is_some() {
                    return false;
                }
            }
            RouteAttribute::PrefSource(address) => {
                let address = match parse_route_addr(address) {
                    Ok(address) => address,
                    Err(_) => return false,
                };
                if preferred_source.replace(address).is_some() {
                    return false;
                }
            }
            RouteAttribute::Oif(index) => {
                if output_interface.replace(*index).is_some() {
                    return false;
                }
            }
            RouteAttribute::Source(_)
            | RouteAttribute::Gateway(_)
            | RouteAttribute::Via(_)
            | RouteAttribute::MultiPath(_) => return false,
            _ => {}
        }
    }

    let expected_destination = match expected.destination {
        IpNetwork::V4(network) => IpAddr::V4(network.network()),
        IpNetwork::V6(network) => IpAddr::V6(network.network()),
    };
    if destination != Some(expected_destination)
        || output_interface != Some(expected.output_interface)
        || preferred_source.is_some_and(|source| source != expected.preferred_source)
    {
        return false;
    }

    match expected.family {
        AddressFamily::Inet => preferred_source == Some(expected.preferred_source),
        AddressFamily::Inet6 => true,
        _ => false,
    }
}

/// Search criteria to use when looking for a link in `find_link`.
pub enum LinkFilter<'a> {
    /// Find by link name.
    Name(&'a str),
    /// Find by link index.
    Index(u32),
    /// Find by MAC address.
    Address(&'a str),
}

impl fmt::Display for LinkFilter<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LinkFilter::Name(name) => write!(f, "Name: {}", name),
            LinkFilter::Index(idx) => write!(f, "Index: {}", idx),
            LinkFilter::Address(addr) => write!(f, "Address: {}", addr),
        }
    }
}

/// A filter to query addresses.
pub enum AddressFilter {
    /// Return addresses that belong to the given interface.
    LinkIndex(u32),
    /// Get addresses with the given prefix.
    #[allow(dead_code)]
    IpAddress(IpAddr),
}

/// A high level wrapper for netlink (and `rtnetlink` crate) for use by the Agent's RPC.
/// It is expected to be consumed by the `AgentService`, so it operates with protobuf
/// structures directly for convenience.
#[derive(Debug)]
pub struct Handle {
    handle: rtnetlink::Handle,
}

impl Handle {
    pub(crate) fn new() -> Result<Handle> {
        let (conn, handle, _) = new_connection()?;
        tokio::spawn(conn);

        Ok(Handle { handle })
    }

    pub async fn update_interface(&mut self, iface: &Interface) -> Result<()> {
        // The reliable way to find link is using hardware address
        // as filter. However, hardware filter might not be supported
        // by netlink, we may have to dump link list and the find the
        // target link. filter using name or family is supported, but
        // we cannot use that to find target link.
        // let's try if hardware address filter works. -_-
        let link = self.find_link(LinkFilter::Address(&iface.hwAddr)).await?;

        // Bring down interface if it is UP
        if link.is_up() {
            self.enable_link(link.index(), false).await?;
        }

        // Delete all addresses associated with the link
        let addresses = self
            .list_addresses(AddressFilter::LinkIndex(link.index()))
            .await?;
        self.delete_addresses(addresses).await?;

        // Add new ip addresses from request
        for ip_address in &iface.IPAddresses {
            let ip = IpAddr::from_str(ip_address.address())?;
            let mask = ip_address.mask().parse::<u8>()?;

            self.add_addresses(link.index(), std::iter::once(IpNetwork::new(ip, mask)?))
                .await?;
        }

        // Update link
        let mut request = self.handle.link().set(link.index());
        request.message_mut().header = link.header.clone();

        request
            .mtu(iface.mtu as _)
            .name(iface.name.clone())
            .arp(iface.raw_flags & libc::IFF_NOARP as u32 == 0)
            .up()
            .execute()
            .await?;

        Ok(())
    }

    pub async fn handle_localhost(&self) -> Result<()> {
        let link = self.find_link(LinkFilter::Name("lo")).await?;
        self.enable_link(link.index(), true).await?;
        Ok(())
    }

    pub async fn update_routes<I>(&mut self, list: I) -> Result<()>
    where
        I: IntoIterator<Item = Route>,
    {
        let old_routes = self
            .query_routes(None)
            .await
            .with_context(|| "Failed to query old routes")?;

        self.delete_routes(old_routes)
            .await
            .with_context(|| "Failed to delete old routes")?;

        self.add_routes(list)
            .await
            .with_context(|| "Failed to add new routes")?;

        Ok(())
    }

    /// Retireve available network interfaces.
    pub async fn list_interfaces(&self) -> Result<Vec<Interface>> {
        let mut list = Vec::new();

        let links = self.list_links().await?;

        for link in &links {
            let mut iface = Interface {
                name: link.name(),
                hwAddr: link.address(),
                mtu: link.mtu().unwrap_or(0),
                ..Default::default()
            };

            let ips = self
                .list_addresses(AddressFilter::LinkIndex(link.index()))
                .await?
                .into_iter()
                .map(|p| p.try_into())
                .collect::<Result<Vec<IPAddress>>>()?;

            iface.IPAddresses = ips;

            list.push(iface);
        }

        Ok(list)
    }

    async fn find_link(&self, filter: LinkFilter<'_>) -> Result<Link> {
        let request = self.handle.link().get();

        let filtered = match filter {
            LinkFilter::Name(name) => request.match_name(name.to_owned()),
            LinkFilter::Index(index) => request.match_index(index),
            _ => request, // Post filters
        };

        let mut stream = filtered.execute();

        let next = if let LinkFilter::Address(addr) = filter {
            let mac_addr = parse_mac_address(addr)
                .with_context(|| format!("Failed to parse MAC address: {}", addr))?;

            // Hardware filter might not be supported by netlink,
            // we may have to dump link list and the find the target link.
            stream
                .try_filter(|f| {
                    let result = f.attributes.iter().any(|n| match n {
                        LinkAttribute::Address(data) => data.eq(&mac_addr),
                        _ => false,
                    });

                    future::ready(result)
                })
                .try_next()
                .await?
        } else {
            stream.try_next().await?
        };

        next.map(|msg| msg.into())
            .ok_or_else(|| anyhow!("Link not found ({})", filter))
    }

    async fn list_links(&self) -> Result<Vec<Link>> {
        let result = self
            .handle
            .link()
            .get()
            .execute()
            .try_filter_map(|msg| future::ready(Ok(Some(msg.into())))) // Don't filter, just map
            .try_collect::<Vec<Link>>()
            .await?;
        Ok(result)
    }

    pub async fn enable_link(&self, link_index: u32, up: bool) -> Result<()> {
        let link_req = self.handle.link().set(link_index);
        let set_req = if up { link_req.up() } else { link_req.down() };
        set_req.execute().await?;
        Ok(())
    }

    async fn query_routes(&self, ip_version: Option<IpVersion>) -> Result<Vec<RouteMessage>> {
        let list = if let Some(ip_version) = ip_version {
            self.handle
                .route()
                .get(ip_version)
                .execute()
                .try_collect()
                .await?
        } else {
            // These queries must be executed sequentially, otherwise
            // it'll throw "Device or resource busy (os error 16)"
            let routes4 = self
                .handle
                .route()
                .get(IpVersion::V4)
                .execute()
                .try_collect::<Vec<_>>()
                .await
                .with_context(|| "Failed to query IP v4 routes")?;

            let routes6 = self
                .handle
                .route()
                .get(IpVersion::V6)
                .execute()
                .try_collect::<Vec<_>>()
                .await
                .with_context(|| "Failed to query IP v6 routes")?;

            [routes4, routes6].concat()
        };

        Ok(list)
    }

    async fn connected_route_exists(&self, route: &Route, output_interface: u32) -> Result<bool> {
        let expected = match connected_route_identity(route, output_interface) {
            Some(expected) => expected,
            None => return Ok(false),
        };
        let version = if expected.family == AddressFamily::Inet6 {
            IpVersion::V6
        } else {
            IpVersion::V4
        };
        let route_matches = self
            .query_routes(Some(version))
            .await?
            .iter()
            .any(|message| matches_connected_route(message, &expected));
        if !route_matches {
            return Ok(false);
        }

        // This is required even when RTA_PREFSRC is present: it prevents a
        // coincidentally identical route on an interface which does not own
        // the source address from being accepted as the CNI connected route.
        let source = expected.preferred_source.to_string();
        Ok(self
            .list_addresses(Some(AddressFilter::LinkIndex(output_interface)))
            .await?
            .iter()
            .any(|address| address.address() == source || address.local() == source))
    }

    pub async fn list_routes(&self) -> Result<Vec<Route>> {
        let mut result = Vec::new();

        for msg in self.query_routes(None).await? {
            // Ignore non-main tables
            if msg.header.table != RouteHeader::RT_TABLE_MAIN {
                continue;
            }

            let mut route = Route {
                scope: u8::from(msg.header.scope) as u32,
                ..Default::default()
            };

            for attribute in &msg.attributes {
                if let RouteAttribute::Destination(dest) = attribute {
                    if let Ok(dest) = parse_route_addr(dest) {
                        route.dest = format!("{}/{}", dest, msg.header.destination_prefix_length);
                    }
                }

                if let RouteAttribute::Source(src) = attribute {
                    if let Ok(src) = parse_route_addr(src) {
                        route.source = format!("{}/{}", src, msg.header.source_prefix_length)
                    }
                }

                if let RouteAttribute::Gateway(g) = attribute {
                    if let Ok(addr) = parse_route_addr(g) {
                        // For gateway, destination is 0.0.0.0
                        if addr.is_ipv4() {
                            route.dest = String::from("0.0.0.0");
                        } else {
                            route.dest = String::from("::1");
                        }
                    }

                    route.gateway = parse_route_addr(g)
                        .map(|g| g.to_string())
                        .unwrap_or_default();
                }

                if let RouteAttribute::Oif(index) = attribute {
                    route.device = self.find_link(LinkFilter::Index(*index)).await?.name();
                }
            }

            if !route.dest.is_empty() {
                result.push(route);
            }
        }

        Ok(result)
    }

    /// Adds a list of routes from iterable object `I`.
    /// It can accept both a collection of routes or a single item (via `iter::once()`).
    /// It'll also take care of proper order when adding routes (gateways first, everything else after).
    pub async fn add_routes<I>(&mut self, list: I) -> Result<()>
    where
        I: IntoIterator<Item = Route>,
    {
        // Split the list so we add routes with no gateway first.
        // Note: `partition_in_place` is a better fit here, since it reorders things inplace (instead of
        // allocating two separate collections), however it's not yet in stable Rust.
        let (a, b): (Vec<Route>, Vec<Route>) = list.into_iter().partition(|p| p.gateway.is_empty());
        let list = a.iter().chain(&b);

        for route in list {
            debug!(sl!(), "add_routes: route:{:?}", route);
            let link = self.find_link(LinkFilter::Name(&route.device)).await?;

            const MAIN_TABLE: u32 = libc::RT_TABLE_MAIN as u32;
            let uni_cast: RouteType = RouteType::from(libc::RTN_UNICAST);
            let boot_prot: RouteProtocol = RouteProtocol::from(libc::RTPROT_BOOT);

            let scope = RouteScope::from(route.scope as u8);

            // Build a common indeterminate ip request
            let mut request = self
                .handle
                .route()
                .add()
                .table_id(MAIN_TABLE)
                .kind(uni_cast)
                .protocol(boot_prot)
                .scope(scope);

            if route.onlink {
                request.message_mut().header.flags.push(RouteFlag::Onlink);
            }

            // `rtnetlink` offers a separate request builders for different IP versions (IP v4 and v6).
            // This if branch is a bit clumsy because it does almost the same.
            if route.family() == IPFamily::v6 {
                let dest_addr = if !route.dest.is_empty() {
                    Ipv6Network::from_str(&route.dest)?
                } else {
                    Ipv6Network::new(Ipv6Addr::new(0, 0, 0, 0, 0, 0, 0, 0), 0)?
                };

                // Build IP v6 request
                let mut request = request
                    .v6()
                    .destination_prefix(dest_addr.ip(), dest_addr.prefix())
                    .output_interface(link.index());

                if !route.source.is_empty() {
                    let network = Ipv6Network::from_str(&route.source)?;
                    if network.prefix() > 0 {
                        if route.onlink {
                            request = request.pref_source(network.ip());
                        } else {
                            request = request.source_prefix(network.ip(), network.prefix());
                        }
                    } else {
                        request
                            .message_mut()
                            .attributes
                            .push(RouteAttribute::PrefSource(RouteAddress::from(network.ip())));
                    }
                }

                if !route.gateway.is_empty() {
                    let ip = Ipv6Addr::from_str(&route.gateway)?;
                    request = request.gateway(ip);
                }

                if let Err(err) = request.execute().await {
                    let eexist = matches!(
                        &err,
                        rtnetlink::Error::NetlinkError(message)
                            if message.code.map(|code| code.get()) == Some(-libc::EEXIST)
                    );
                    if eexist
                        && self
                            .connected_route_exists(route, link.index())
                            .await
                            .with_context(|| "read back existing IP v6 route")?
                    {
                        continue;
                    }
                    return Err(anyhow!(
                        "Failed to add IP v6 route (src: {}, dst: {}, gtw: {}, Err: {})",
                        route.source(),
                        route.dest(),
                        route.gateway(),
                        err
                    ));
                }
            } else {
                let dest_addr = if !route.dest.is_empty() {
                    Ipv4Network::from_str(&route.dest)?
                } else {
                    Ipv4Network::new(Ipv4Addr::new(0, 0, 0, 0), 0)?
                };

                // Build IP v4 request
                let mut request = request
                    .v4()
                    .destination_prefix(dest_addr.ip(), dest_addr.prefix())
                    .output_interface(link.index());
                debug!(
                    sl!(),
                    "add_routes:  dest_addr ip:{:?}, prefix:{:?}",
                    dest_addr.ip(),
                    dest_addr.prefix()
                );

                if !route.source.is_empty() {
                    let network = Ipv4Network::from_str(&route.source)?;

                    if network.prefix() > 0 {
                        if route.onlink {
                            request = request.pref_source(network.ip());
                        } else {
                            request = request.source_prefix(network.ip(), network.prefix());
                        }
                    } else {
                        request
                            .message_mut()
                            .attributes
                            .push(RouteAttribute::PrefSource(RouteAddress::from(network.ip())));
                    }
                }

                if !route.gateway.is_empty() {
                    let ip = Ipv4Addr::from_str(&route.gateway)?;
                    request = request.gateway(ip);
                }

                if let Err(err) = request.execute().await {
                    let eexist = matches!(
                        &err,
                        rtnetlink::Error::NetlinkError(message)
                            if message.code.map(|code| code.get()) == Some(-libc::EEXIST)
                    );
                    if eexist
                        && self
                            .connected_route_exists(route, link.index())
                            .await
                            .with_context(|| "read back existing IP v4 route")?
                    {
                        continue;
                    }
                    return Err(anyhow!(
                        "Failed to add IP v4 route (src: {}, dst: {}, gtw: {}, Err: {})",
                        route.source(),
                        route.dest(),
                        route.gateway(),
                        err
                    ));
                }
            }
        }

        Ok(())
    }

    async fn delete_routes<I>(&mut self, routes: I) -> Result<()>
    where
        I: IntoIterator<Item = RouteMessage>,
    {
        for route in routes.into_iter() {
            if route.header.protocol == RouteProtocol::Kernel {
                continue;
            }

            let index = if let Some(index) = route_msg_output_interface(&route) {
                index
            } else {
                continue;
            };

            let link = self.find_link(LinkFilter::Index(index)).await?;

            let name = link.name();
            if name.contains("lo") || name.contains("::1") {
                continue;
            }

            self.handle.route().del(route).execute().await?;
        }

        Ok(())
    }

    async fn list_addresses<F>(&self, filter: F) -> Result<Vec<Address>>
    where
        F: Into<Option<AddressFilter>>,
    {
        let mut request = self.handle.address().get();

        if let Some(filter) = filter.into() {
            request = match filter {
                AddressFilter::LinkIndex(index) => request.set_link_index_filter(index),
                AddressFilter::IpAddress(addr) => request.set_address_filter(addr),
            };
        };

        let list = request
            .execute()
            .try_filter_map(|msg| future::ready(Ok(Some(Address(msg))))) // Map message to `Address`
            .try_collect()
            .await?;
        Ok(list)
    }

    async fn add_addresses<I>(&mut self, index: u32, list: I) -> Result<()>
    where
        I: IntoIterator<Item = IpNetwork>,
    {
        for net in list.into_iter() {
            self.handle
                .address()
                .add(index, net.ip(), net.prefix())
                .execute()
                .await
                .map_err(|err| anyhow!("Failed to add address {}: {:?}", net.ip(), err))?;
        }

        Ok(())
    }

    async fn delete_addresses<I>(&mut self, list: I) -> Result<()>
    where
        I: IntoIterator<Item = Address>,
    {
        for addr in list.into_iter() {
            self.handle.address().del(addr.0).execute().await?;
        }

        Ok(())
    }

    pub async fn add_arp_neighbors<I>(&mut self, list: I) -> Result<()>
    where
        I: IntoIterator<Item = ARPNeighbor>,
    {
        for neigh in list.into_iter() {
            self.add_arp_neighbor(&neigh).await.map_err(|err| {
                anyhow!(
                    "Failed to add ARP neighbor {}: {:?}",
                    neigh.toIPAddress().address(),
                    err
                )
            })?;
        }

        Ok(())
    }

    /// Adds an ARP neighbor.
    /// TODO: `rtnetlink` has no neighbours API, remove this after https://github.com/little-dude/netlink/pull/135
    async fn add_arp_neighbor(&mut self, neigh: &ARPNeighbor) -> Result<()> {
        let ip_address = neigh
            .toIPAddress
            .as_ref()
            .map(|to| to.address.as_str()) // Extract address field
            .and_then(|addr| if addr.is_empty() { None } else { Some(addr) }) // Make sure it's not empty
            .ok_or_else(|| anyhow!(nix::Error::EINVAL))?;

        let ip = IpAddr::from_str(ip_address)
            .map_err(|e| anyhow!("Failed to parse IP {}: {:?}", ip_address, e))?;

        // Import rtnetlink objects that make sense only for this function
        use libc::{NLM_F_ACK, NLM_F_CREATE, NLM_F_REPLACE, NLM_F_REQUEST};
        use neighbour::{NeighbourHeader, NeighbourMessage};
        use netlink_packet_core::{NetlinkMessage, NetlinkPayload};
        use netlink_packet_route::RouteNetlinkMessage;
        use rtnetlink::Error;

        const IFA_F_PERMANENT: u16 = 0x80; // See https://github.com/little-dude/netlink/blob/0185b2952505e271805902bf175fee6ea86c42b8/netlink-packet-route/src/rtnl/constants.rs#L770

        let state = if neigh.state != 0 {
            neigh.state as u16
        } else {
            IFA_F_PERMANENT
        };
        let state = NeighbourState::from(state);

        let link = self.find_link(LinkFilter::Name(&neigh.device)).await?;
        let mut flags = Vec::new();
        for flag in ALL_RULE_FLAGS {
            if (neigh.flags as u8 & (u8::from(flag))) > 0 {
                flags.push(flag);
            }
        }
        let mut message = NeighbourMessage::default();
        message.header = NeighbourHeader {
            family: match ip {
                IpAddr::V4(_) => AddressFamily::Inet,
                IpAddr::V6(_) => AddressFamily::Inet6,
            },
            ifindex: link.index(),
            state,
            flags,
            kind: RouteType::Unspec,
        };

        let mut nlas = vec![NeighbourAttribute::Destination(match ip {
            IpAddr::V4(ipv4_addr) => NeighbourAddress::from(ipv4_addr),
            IpAddr::V6(ipv6_addr) => NeighbourAddress::from(ipv6_addr),
        })];

        if !neigh.lladdr.is_empty() {
            nlas.push(NeighbourAttribute::LinkLocalAddress(
                parse_mac_address(&neigh.lladdr)?.to_vec(),
            ));
        }
        message.attributes = nlas;

        // Send request and ACK
        let mut req = NetlinkMessage::from(RouteNetlinkMessage::NewNeighbour(message));
        req.header.flags = (NLM_F_REQUEST | NLM_F_ACK | NLM_F_REPLACE | NLM_F_CREATE) as u16;

        let mut response = self.handle.request(req)?;
        while let Some(message) = response.next().await {
            if let NetlinkPayload::Error(err) = message.payload {
                return Err(anyhow!(Error::NetlinkError(err)));
            }
        }

        Ok(())
    }
}

fn format_address(data: &[u8]) -> Result<String> {
    match data.len() {
        4 => {
            // IP v4
            Ok(format!("{}.{}.{}.{}", data[0], data[1], data[2], data[3]))
        }
        6 => {
            // Mac address
            Ok(format!(
                "{:0>2X}:{:0>2X}:{:0>2X}:{:0>2X}:{:0>2X}:{:0>2X}",
                data[0], data[1], data[2], data[3], data[4], data[5]
            ))
        }
        16 => {
            // IP v6
            let octets = <[u8; 16]>::try_from(data)?;
            Ok(Ipv6Addr::from(octets).to_string())
        }
        _ => Err(anyhow!("Unsupported address length: {}", data.len())),
    }
}

fn parse_mac_address(addr: &str) -> Result<[u8; 6]> {
    let mut split = addr.splitn(6, ':');

    // Parse single Mac address block
    let mut parse_next = || -> Result<u8> {
        let v = u8::from_str_radix(split.next().ok_or_else(|| anyhow!(nix::Error::EINVAL))?, 16)?;
        Ok(v)
    };

    // Parse all 6 blocks
    let arr = [
        parse_next()?,
        parse_next()?,
        parse_next()?,
        parse_next()?,
        parse_next()?,
        parse_next()?,
    ];

    Ok(arr)
}

/// Wraps external type with the local one, so we can implement various extensions and type conversions.
struct Link(LinkMessage);

impl Link {
    /// If name.
    fn name(&self) -> String {
        self.attributes
            .iter()
            .find_map(|n| {
                if let LinkAttribute::IfName(name) = n {
                    Some(name.clone())
                } else {
                    None
                }
            })
            .unwrap_or_default()
    }

    /// Extract Mac address.
    fn address(&self) -> String {
        self.attributes
            .iter()
            .find_map(|n| {
                if let LinkAttribute::Address(data) = n {
                    format_address(&data).ok()
                } else {
                    None
                }
            })
            .unwrap_or_default()
    }

    /// Returns whether the link is UP
    fn is_up(&self) -> bool {
        let mut flags: u32 = 0;
        for flag in &self.header.flags {
            flags |= u32::from(*flag);
        }

        flags as i32 & libc::IFF_UP > 0
    }

    fn index(&self) -> u32 {
        self.header.index
    }

    fn mtu(&self) -> Option<u64> {
        self.attributes.iter().find_map(|n| {
            if let LinkAttribute::Mtu(mtu) = n {
                Some(*mtu as u64)
            } else {
                None
            }
        })
    }
}

impl From<LinkMessage> for Link {
    fn from(msg: LinkMessage) -> Self {
        Link(msg)
    }
}

impl Deref for Link {
    type Target = LinkMessage;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

struct Address(AddressMessage);

impl TryFrom<Address> for IPAddress {
    type Error = anyhow::Error;

    fn try_from(value: Address) -> Result<Self, Self::Error> {
        let family = if value.is_ipv6() {
            IPFamily::v4
        } else {
            IPFamily::v6
        };

        let mut address = value.address();
        if address.is_empty() {
            address = value.local();
        }

        let mask = format!("{}", value.0.header.prefix_len);

        Ok(IPAddress {
            family: family.into(),
            address,
            mask,
            ..Default::default()
        })
    }
}

impl Address {
    fn is_ipv6(&self) -> bool {
        u8::from(self.0.header.family) == libc::AF_INET6 as u8
    }

    #[allow(dead_code)]
    fn prefix(&self) -> u8 {
        self.0.header.prefix_len
    }

    fn address(&self) -> String {
        use AddressAttribute as Nla;
        self.0
            .attributes
            .iter()
            .find_map(|n| {
                if let Nla::Address(data) = n {
                    Some(data.to_string())
                } else {
                    None
                }
            })
            .unwrap_or_default()
    }

    fn local(&self) -> String {
        use AddressAttribute as Nla;
        self.0
            .attributes
            .iter()
            .find_map(|n| {
                if let Nla::Local(data) = n {
                    Some(data.to_string())
                } else {
                    None
                }
            })
            .unwrap_or_default()
    }
}

fn route_msg_output_interface(msg: &RouteMessage) -> Option<u32> {
    msg.attributes.iter().find_map(|nla| {
        if let RouteAttribute::Oif(v) = nla {
            Some(*v)
        } else {
            None
        }
    })
}

fn parse_route_addr(ra: &RouteAddress) -> Result<IpAddr> {
    let ipaddr = match ra {
        RouteAddress::Inet6(ipv6_addr) => ipv6_addr.to_canonical(),
        RouteAddress::Inet(ipv4_addr) => IpAddr::from(*ipv4_addr),
        _ => return Err(anyhow!("got invalid route address")),
    };

    Ok(ipaddr)
}

#[cfg(test)]
mod tests {
    use netlink_packet_route::address::AddressHeader;
    use netlink_packet_route::link::LinkHeader;

    use super::*;
    use crate::{skip_if_no_cap, skip_if_not_root};
    use capctl::caps::Cap;
    use serial_test::serial;
    use std::iter;
    use std::os::unix::io::AsRawFd;
    use std::process::Command;

    fn route(dest: &str, source: &str, gateway: &str) -> Route {
        let mut route = Route {
            dest: dest.to_owned(),
            source: source.to_owned(),
            gateway: gateway.to_owned(),
            ..Default::default()
        };
        if dest.contains(':') || source.contains(':') || gateway.contains(':') {
            route.set_family(IPFamily::v6);
            route.scope = u8::from(RouteScope::Universe) as u32;
        } else {
            route.scope = u8::from(RouteScope::Link) as u32;
        }
        route
    }

    fn connected_message(dest: &str, source: Option<&str>, oif: u32) -> RouteMessage {
        let network = IpNetwork::from_str(dest).unwrap();
        let mut message = RouteMessage::default();
        message.header.address_family = if network.is_ipv4() {
            AddressFamily::Inet
        } else {
            AddressFamily::Inet6
        };
        message.header.destination_prefix_length = network.prefix();
        message.header.table = RouteHeader::RT_TABLE_MAIN;
        message.header.protocol = RouteProtocol::Kernel;
        message.header.scope = if network.is_ipv4() {
            RouteScope::Link
        } else {
            RouteScope::Universe
        };
        message.header.kind = RouteType::Unicast;
        let destination = match network {
            IpNetwork::V4(network) => RouteAddress::from(network.network()),
            IpNetwork::V6(network) => RouteAddress::from(network.network()),
        };
        message
            .attributes
            .push(RouteAttribute::Destination(destination));
        message.attributes.push(RouteAttribute::Oif(oif));
        if let Some(source) = source {
            let source = IpAddr::from_str(source).unwrap();
            let source = match source {
                IpAddr::V4(source) => RouteAddress::from(source),
                IpAddr::V6(source) => RouteAddress::from(source),
            };
            message.attributes.push(RouteAttribute::PrefSource(source));
        }
        message
    }

    #[test]
    fn connected_route_readback_requires_exact_identity() {
        let route4 = route("10.254.0.0/24", "10.254.0.21", "");
        let expected4 = connected_route_identity(&route4, 7).unwrap();
        let message4 = connected_message("10.254.0.0/24", Some("10.254.0.21"), 7);
        assert!(matches_connected_route(&message4, &expected4));

        let route6 = route("fd00::/64", "fd00::21", "");
        let expected6 = connected_route_identity(&route6, 9).unwrap();
        let message6 = connected_message("fd00::/64", None, 9);
        assert!(matches_connected_route(&message6, &expected6));

        let mut conflict = message4.clone();
        conflict
            .attributes
            .retain(|attribute| !matches!(attribute, RouteAttribute::Oif(_)));
        conflict.attributes.push(RouteAttribute::Oif(8));
        assert!(!matches_connected_route(&conflict, &expected4));

        let mut conflict = message4.clone();
        conflict.header.protocol = RouteProtocol::Boot;
        assert!(!matches_connected_route(&conflict, &expected4));

        let mut conflict = message4.clone();
        conflict.header.scope = RouteScope::Universe;
        assert!(!matches_connected_route(&conflict, &expected4));

        let mut conflict = message4.clone();
        conflict.header.kind = RouteType::BlackHole;
        assert!(!matches_connected_route(&conflict, &expected4));

        let mut conflict = message4.clone();
        conflict.header.table = libc::RT_TABLE_LOCAL as u8;
        assert!(!matches_connected_route(&conflict, &expected4));

        let mut conflict = message4.clone();
        conflict.header.source_prefix_length = 32;
        assert!(!matches_connected_route(&conflict, &expected4));

        let mut conflict = message4.clone();
        conflict.header.flags.push(RouteFlag::Onlink);
        assert!(!matches_connected_route(&conflict, &expected4));

        let conflict = connected_message("10.253.0.0/24", Some("10.254.0.21"), 7);
        assert!(!matches_connected_route(&conflict, &expected4));

        let mut conflict = message4.clone();
        conflict
            .attributes
            .push(RouteAttribute::Gateway(RouteAddress::from(Ipv4Addr::new(
                10, 254, 0, 1,
            ))));
        assert!(!matches_connected_route(&conflict, &expected4));

        let mut conflict = message4.clone();
        conflict
            .attributes
            .retain(|attribute| !matches!(attribute, RouteAttribute::PrefSource(_)));
        conflict
            .attributes
            .push(RouteAttribute::PrefSource(RouteAddress::from(
                Ipv4Addr::new(10, 254, 0, 22),
            )));
        assert!(!matches_connected_route(&conflict, &expected4));

        assert!(connected_route_identity(&route("0.0.0.0/0", "10.254.0.21", ""), 7).is_none());
        assert!(
            connected_route_identity(&route("10.254.0.0/24", "10.254.0.0/24", ""), 7).is_none()
        );
        assert!(
            connected_route_identity(&route("10.254.0.0/24", "10.254.0.21", "10.254.0.1"), 7)
                .is_none()
        );
        let mut wrong_scope = route("10.254.0.0/24", "10.254.0.21", "");
        wrong_scope.scope = u8::from(RouteScope::Universe) as u32;
        assert!(connected_route_identity(&wrong_scope, 7).is_none());
    }

    fn run_ip(args: &[&str]) -> std::result::Result<(), String> {
        let output = Command::new("ip")
            .args(args)
            .output()
            .map_err(|error| format!("ip {:?} failed to execute: {}", args, error))?;
        if output.status.success() {
            Ok(())
        } else {
            Err(format!(
                "ip {:?} failed: {}",
                args,
                String::from_utf8_lossy(&output.stderr)
            ))
        }
    }

    #[tokio::test(flavor = "current_thread")]
    #[serial(netns)]
    async fn connected_route_eexist_is_verified_in_kernel() {
        skip_if_not_root!();
        skip_if_no_cap!(Cap::NET_ADMIN);
        skip_if_no_cap!(Cap::SYS_ADMIN);

        let original = std::fs::File::open("/proc/self/ns/net").unwrap();
        if let Err(error) = nix::sched::unshare(nix::sched::CloneFlags::CLONE_NEWNET) {
            println!("INFO: skipping netns route test: unshare failed: {}", error);
            return;
        }
        defer!(let _ = nix::sched::setns(original.as_raw_fd(), nix::sched::CloneFlags::CLONE_NEWNET););

        // Some distributions create new network namespaces with IPv6 disabled
        // even when the host namespace has it enabled. Turn it on inside this
        // throwaway namespace so the v6 connected-route branch is exercised.
        for sysctl in [
            "/proc/sys/net/ipv6/conf/all/disable_ipv6",
            "/proc/sys/net/ipv6/conf/default/disable_ipv6",
        ] {
            if std::path::Path::new(sysctl).exists() {
                std::fs::write(sysctl, b"0").unwrap();
            }
        }

        if let Err(error) = run_ip(&["link", "add", "cube-e2e0", "type", "dummy"]) {
            println!("INFO: skipping netns route test: {}", error);
            return;
        }
        run_ip(&["link", "add", "cube-e2e1", "type", "dummy"]).unwrap();
        for interface in ["cube-e2e0", "cube-e2e1"] {
            std::fs::write(
                format!("/proc/sys/net/ipv6/conf/{}/disable_ipv6", interface),
                b"0",
            )
            .unwrap();
        }
        run_ip(&["link", "set", "cube-e2e0", "up"]).unwrap();
        run_ip(&["link", "set", "cube-e2e1", "up"]).unwrap();
        run_ip(&["addr", "add", "192.0.2.2/24", "dev", "cube-e2e0"]).unwrap();
        run_ip(&["-6", "addr", "add", "2001:db8:1::2/64", "dev", "cube-e2e0"]).unwrap();

        let mut handle = Handle::new().unwrap();
        let link = handle
            .find_link(LinkFilter::Name("cube-e2e0"))
            .await
            .unwrap();
        let mut route4 = route("192.0.2.0/24", "192.0.2.2", "");
        route4.device = "cube-e2e0".to_string();
        assert!(handle
            .connected_route_exists(&route4, link.index())
            .await
            .unwrap());
        let routes4_before = handle.query_routes(Some(IpVersion::V4)).await.unwrap();
        handle.add_routes(iter::once(route4.clone())).await.unwrap();
        let routes4_after = handle.query_routes(Some(IpVersion::V4)).await.unwrap();
        assert_eq!(routes4_after, routes4_before);

        let mut conflict = route4;
        conflict.device = "cube-e2e1".to_string();
        assert!(handle.add_routes(iter::once(conflict)).await.is_err());

        let mut route6 = route("2001:db8:1::/64", "2001:db8:1::2", "");
        route6.device = "cube-e2e0".to_string();
        assert!(handle
            .connected_route_exists(&route6, link.index())
            .await
            .unwrap());
        let routes6_before = handle.query_routes(Some(IpVersion::V6)).await.unwrap();
        handle.add_routes(iter::once(route6)).await.unwrap();
        let routes6_after = handle.query_routes(Some(IpVersion::V6)).await.unwrap();
        assert_eq!(routes6_after, routes6_before);
    }

    #[tokio::test]
    async fn find_link_by_name() {
        let message = Handle::new()
            .expect("Failed to create netlink handle")
            .find_link(LinkFilter::Name("lo"))
            .await
            .expect("Loopback not found");

        assert_ne!(message.header, LinkHeader::default());
        assert_eq!(message.name(), "lo");
    }

    #[tokio::test]
    async fn find_link_by_addr() {
        let handle = Handle::new().unwrap();

        let list = handle.list_links().await.unwrap();
        let link = list.first().expect("At least one link required");

        let result = handle
            .find_link(LinkFilter::Address(&link.address()))
            .await
            .expect("Failed to query link by address");

        assert_eq!(result.header.index, link.header.index);
    }

    #[tokio::test]
    async fn link_up() {
        skip_if_not_root!();
        // Bringing a link up requires CAP_NET_ADMIN.
        skip_if_no_cap!(Cap::NET_ADMIN);

        let handle = Handle::new().unwrap();
        let link = handle.find_link(LinkFilter::Name("lo")).await.unwrap();

        handle
            .enable_link(link.header.index, true)
            .await
            .expect("Failed to bring link up");

        assert!(handle
            .find_link(LinkFilter::Name("lo"))
            .await
            .unwrap()
            .is_up());
    }

    #[tokio::test]
    async fn link_ext() {
        let lo = Handle::new()
            .unwrap()
            .find_link(LinkFilter::Name("lo"))
            .await
            .unwrap();

        assert_eq!(lo.name(), "lo");
        assert_ne!(lo.address().len(), 0);
    }

    #[tokio::test]
    async fn list_routes() {
        let all = Handle::new()
            .unwrap()
            .list_routes()
            .await
            .expect("Failed to list routes");

        assert_ne!(all.len(), 0);

        for r in &all {
            assert_ne!(r.device.len(), 0);
        }
    }

    #[tokio::test]
    async fn list_addresses() {
        let list = Handle::new()
            .unwrap()
            .list_addresses(None)
            .await
            .expect("Failed to list addresses");

        assert_ne!(list.len(), 0);
        for addr in &list {
            assert_ne!(addr.0.header, AddressHeader::default());
        }
    }

    #[tokio::test]
    async fn list_interfaces() {
        let list = Handle::new()
            .unwrap()
            .list_interfaces()
            .await
            .expect("Failed to list interfaces");

        for iface in &list {
            assert_ne!(iface.name.len(), 0);
            assert_ne!(iface.mtu, 0);

            for ip in &iface.IPAddresses {
                assert_ne!(ip.mask.len(), 0);
                assert_ne!(ip.address.len(), 0);
            }
        }
    }

    #[tokio::test]
    async fn add_delete_addresses() {
        skip_if_not_root!();
        // Adding/removing link addresses requires CAP_NET_ADMIN.
        skip_if_no_cap!(Cap::NET_ADMIN);

        let list = vec![
            IpNetwork::from_str("169.254.1.1/31").unwrap(),
            IpNetwork::from_str("2001:db8:85a3::8a2e:370:7334/128").unwrap(),
        ];

        let mut handle = Handle::new().unwrap();
        let lo = handle.find_link(LinkFilter::Name("lo")).await.unwrap();

        for network in list {
            handle
                .add_addresses(lo.index(), iter::once(network))
                .await
                .expect("Failed to add IP");

            // Make sure the address is there
            let result = handle
                .list_addresses(AddressFilter::LinkIndex(lo.index()))
                .await
                .unwrap()
                .into_iter()
                .find(|p| {
                    p.prefix() == network.prefix() && p.address() == network.ip().to_string()
                });

            assert!(result.is_some());

            // Delete it
            handle
                .delete_addresses(iter::once(result.unwrap()))
                .await
                .expect("Failed to delete address");
        }
    }

    #[test]
    fn format_addr() {
        let buf = [1u8, 2u8, 3u8, 4u8];
        let addr = format_address(&buf).unwrap();
        assert_eq!(addr, "1.2.3.4");

        let buf = [1u8, 2u8, 3u8, 4u8, 5u8, 10u8];
        let addr = format_address(&buf).unwrap();
        assert_eq!(addr, "01:02:03:04:05:0A");
    }

    #[test]
    fn parse_mac() {
        let bytes = parse_mac_address("AB:0C:DE:12:34:56").expect("Failed to parse mac address");
        assert_eq!(bytes, [0xAB, 0x0C, 0xDE, 0x12, 0x34, 0x56]);
    }

    fn clean_env_for_test_add_one_arp_neighbor(dummy_name: &str, ip: &str) {
        // ip link delete dummy
        Command::new("ip")
            .args(&["link", "delete", dummy_name])
            .output()
            .expect("prepare: failed to delete dummy");

        // ip neigh del dev dummy ip
        Command::new("ip")
            .args(&["neigh", "del", dummy_name, ip])
            .output()
            .expect("prepare: failed to delete neigh");
    }

    fn prepare_env_for_test_add_one_arp_neighbor(dummy_name: &str, ip: &str) {
        clean_env_for_test_add_one_arp_neighbor(dummy_name, ip);
        // modprobe dummy
        Command::new("modprobe")
            .arg("dummy")
            .output()
            .expect("failed to run modprobe dummy");

        // ip link add dummy type dummy
        Command::new("ip")
            .args(&["link", "add", dummy_name, "type", "dummy"])
            .output()
            .expect("failed to add dummy interface");

        // ip addr add 192.168.0.2/16 dev dummy
        Command::new("ip")
            .args(&["addr", "add", "192.168.0.2/16", "dev", dummy_name])
            .output()
            .expect("failed to add ip for dummy");

        // ip link set dummy up;
        Command::new("ip")
            .args(&["link", "set", dummy_name, "up"])
            .output()
            .expect("failed to up dummy");
    }

    #[tokio::test]
    async fn test_add_one_arp_neighbor() {
        skip_if_not_root!();
        // Creating a dummy interface and ARP entries requires CAP_NET_ADMIN.
        skip_if_no_cap!(Cap::NET_ADMIN);

        let mac = "6a:92:3a:59:70:aa";
        let to_ip = "169.254.1.1";
        let dummy_name = "dummy_for_arp";

        prepare_env_for_test_add_one_arp_neighbor(dummy_name, to_ip);

        let mut ip_address = IPAddress::new();
        ip_address.set_address(to_ip.to_string());

        let mut neigh = ARPNeighbor::new();
        neigh.set_toIPAddress(ip_address);
        neigh.set_device(dummy_name.to_string());
        neigh.set_lladdr(mac.to_string());
        neigh.set_state(0x80);

        Handle::new()
            .unwrap()
            .add_arp_neighbor(&neigh)
            .await
            .expect("Failed to add ARP neighbor");

        // ip neigh show dev dummy ip
        let stdout = Command::new("ip")
            .args(&["neigh", "show", "dev", dummy_name, to_ip])
            .output()
            .expect("failed to show neigh")
            .stdout;

        let stdout = std::str::from_utf8(&stdout).expect("failed to conveert stdout");
        assert_eq!(stdout, format!("{} lladdr {} PERMANENT\n", to_ip, mac));

        clean_env_for_test_add_one_arp_neighbor(dummy_name, to_ip);
    }
}
