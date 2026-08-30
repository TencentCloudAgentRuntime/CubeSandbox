# S1.1 dead-shim cleanup probe

This command sends a real containerd 2.3 Sandbox Controller `Create` request,
waits for CubeShim to persist `cube-runtime-resource.json`, kills only that shim
process, and verifies that containerd's dead-shim `delete` action:

- releases the exact Cubelet generation and lease;
- removes the durable cleanup record; and
- removes the containerd sandbox bundle.

Build it from the `sandbox-probe` module:

```bash
go build -o /tmp/s11-crash-probe ./cmd/s11-crash-probe
```

Run it against an isolated containerd and a RuntimeResource test service whose
release marker contains `released SANDBOX_ID GENERATION LEASE_ID`:

```bash
/tmp/s11-crash-probe CONTAINERD_SOCKET CONTAINERD_STATE RELEASE_MARKER SANDBOX_ID
```

Success is reported as `S11_SHIM_KILL_RELEASE_OK`. The command is an opt-in PoC
test utility and is not part of the CubeShim runtime binary.
