// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0
//

package virtiofs

import (
	"fmt"
	"golang.org/x/sys/unix"
	"os"
	"path/filepath"
	"strings"

	"github.com/opencontainers/runtime-spec/specs-go"
	"k8s.io/apimachinery/pkg/util/sets"

	"github.com/tencentcloud/CubeSandbox/Cubelet/pkg/constants"
	"github.com/tencentcloud/CubeSandbox/Cubelet/pkg/container/disk"
)

type ShareDirMapping struct {
	SharePath string
	MountPath string
}

const virtioFsSharePath = "/data/cubelet/"

type VirtiofsConfig struct {
	ID                    string                `json:"id,omitempty"`
	PropagationMountName  string                `json:"propagation_mount_name,omitempty"`
	RateLimiter           disk.RateLimiter      `json:"rate_limiter_config"`
	VirtioBackendFsConfig VirtioBackendFsConfig `json:"backendfs_config"`
}

type VirtioBackendFsConfig struct {
	SharedDir   string   `json:"shared_dir"`
	AllowedDirs []string `json:"allowed_dirs"`
	ReadOnly    bool     `json:"read_only"`
	Cache       int      `json:"cache"`
}

type ErofsImagePath struct {
	Path string `json:"path"`

	LowerDir []string `json:"lower_dir"`
}
type CubeRootfsInfo struct {
	Overlay    *CubeRootfsOverlayInfo `json:"overlay_info,omitempty"`
	Mounts     []CubeRootfsMount      `json:"mounts,omitempty"`
	PmemFile   string                 `json:"pmem_file,omitempty"`
	ErofsImage *ErofsImagePath        `json:"ero_image,omitempty"`
}

type CubeRootfsOverlayInfo struct {
	VirtiofsLowerDir []string `json:"virtiofs_lower_dir,omitempty"`
	HostLowerDir     []string `json:"-"`
}

type CubeRootfsMount struct {
	HostSource     string   `json:"-"`
	VirtiofsID     string   `json:"virtiofs_id"`
	VirtiofsSource string   `json:"virtiofs_source"`
	ContainerDest  string   `json:"container_dest"`
	Type           string   `json:"type"`
	Options        []string `json:"options"`
}

type VirtioMounts struct {
	HostSource     string `json:"-"`
	VirtiofsSource string `json:"source"`
	Destination    string `json:"dest"`
}

type PropagationContainerDirs struct {
	Name         string `json:"name"`
	ContainerDir string `json:"container_dir"`
}

var emptyShareDirPath string

func Init(dataDir string) {
	emptyShareDirPath = filepath.Join(dataDir, "empty_share")
	_ = os.MkdirAll(emptyShareDirPath, os.ModeDir|0755)
}

func CheckVmRelativePath(path string) bool {
	if path == "/" {
		return true
	}
	up := ".." + string(os.PathSeparator)
	rel, err := filepath.Rel(virtioFsSharePath, path)
	if err != nil {
		return false
	}
	if !strings.HasPrefix(rel, up) && rel != ".." {
		return true
	}
	return false
}

func GenVirtiofsConfig(shared []string) (*VirtiofsConfig, error) {
	virtiofsConfig := &VirtiofsConfig{
		VirtioBackendFsConfig: VirtioBackendFsConfig{
			SharedDir: virtioFsSharePath,
			ReadOnly:  true,
			Cache:     constants.VirtiofsCacheNever,
		},
	}

	sharedNames := sets.NewString()
	sharedDirSet := sets.NewString()

	var shareDirs []string
	for _, dir := range shared {
		if sharedDirSet.Has(dir) {
			continue
		}
		sharedDirSet.Insert(dir)
		err := addAndCheckSharePath(dir, &sharedNames)
		if err != nil {
			if strings.Contains(err.Error(), "duplicated") {
				continue
			}
			return nil, err
		}
		shareDirs = append(shareDirs, dir)
	}
	virtiofsConfig.VirtioBackendFsConfig.AllowedDirs = shareDirs
	if len(shareDirs) == 1 && IsReadOnlyMount(shareDirs[0]) {
		virtiofsConfig.VirtioBackendFsConfig.SharedDir = shareDirs[0]
		virtiofsConfig.VirtioBackendFsConfig.AllowedDirs = nil
	}

	return virtiofsConfig, nil
}

func IsReadOnlyMount(path string) bool {
	const erofsSuperMagic = 0xE0F5E1E2
	var stat unix.Statfs_t
	return unix.Statfs(path, &stat) == nil && (stat.Flags&unix.ST_RDONLY != 0 || stat.Type == erofsSuperMagic)
}

func EnsureHostErofsMount(path string) error {
	if IsReadOnlyMount(path) {
		return nil
	}
	hostPath := filepath.Join("/proc/1/root", path)
	if !IsReadOnlyMount(hostPath) {
		return nil
	}
	source, err := mountSource(path, "/proc/1/mountinfo")
	if err != nil {
		return fmt.Errorf("find host EROFS mount %s: %w", path, err)
	}
	if err := unix.Mount(source, path, "erofs", unix.MS_RDONLY, ""); err != nil {
		return fmt.Errorf("mount host EROFS device %s at %s: %w", source, path, err)
	}
	if err := unix.Mount("", path, "", unix.MS_PRIVATE, ""); err != nil {
		_ = unix.Unmount(path, unix.MNT_DETACH)
		return fmt.Errorf("make EROFS mount %s private: %w", path, err)
	}
	return nil
}

func mountSource(path, mountInfoPath string) (string, error) {
	line, err := findMount(path, mountInfoPath)
	if err != nil {
		return "", err
	}
	separator := strings.Index(line, " - ")
	fields := strings.Fields(line[separator+3:])
	if len(fields) < 2 || fields[0] != "erofs" {
		return "", fmt.Errorf("mount %s is not EROFS", path)
	}
	return fields[1], nil
}
func findMount(path, mountInfoPath string) (string, error) {
	data, err := os.ReadFile(mountInfoPath)
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(string(data), "\n") {
		separator := strings.Index(line, " - ")
		if separator < 0 {
			continue
		}
		fields := strings.Fields(line[:separator])
		if len(fields) >= 6 && fields[4] == path {
			return line, nil
		}
	}
	return "", fmt.Errorf("mount %s not found", path)
}

func GenEmptyVirtiofsConfig(readOnly bool, cache int) (*VirtiofsConfig, error) {
	virtiofsConfig, _ := GenVirtiofsConfig([]string{})
	virtiofsConfig.VirtioBackendFsConfig.SharedDir = emptyShareDirPath
	virtiofsConfig.VirtioBackendFsConfig.AllowedDirs = nil
	virtiofsConfig.VirtioBackendFsConfig.Cache = cache
	virtiofsConfig.VirtioBackendFsConfig.ReadOnly = readOnly
	if readOnly {
		virtiofsConfig.PropagationMountName = constants.PropagationVirtioRo
		virtiofsConfig.ID = constants.PropagationVirtioRo
	} else {
		virtiofsConfig.PropagationMountName = constants.PropagationVirtioRw
		virtiofsConfig.ID = constants.PropagationVirtioRw
	}
	return virtiofsConfig, nil
}

func addAndCheckSharePath(sharePath string, sharedNames *sets.String) error {
	sharedName := filepath.Base(sharePath)
	if sharedNames.Has(sharedName) {
		return fmt.Errorf("share path %s is duplicated", sharePath)
	}
	sharedNames.Insert(sharedName)
	if !CheckVmRelativePath(sharePath) {
		return fmt.Errorf("not a valid share path: %s", sharePath)
	}
	return nil
}

func GenMountConfig(mounts []specs.Mount) ([]CubeRootfsMount, error) {
	var cubeMounts []CubeRootfsMount
	for _, m := range mounts {
		if !CheckVmRelativePath(m.Source) {
			return nil, fmt.Errorf("not a valid share path: %s", m.Source)
		}
		cubeMounts = append(cubeMounts, CubeRootfsMount{
			HostSource:     m.Source,
			VirtiofsSource: filepath.Base(m.Source),
			ContainerDest:  m.Destination,
			Type:           m.Type,
			Options:        m.Options,
		})
	}

	return cubeMounts, nil
}

func GenOverlayMountConfig(ovlShare []ShareDirMapping) *CubeRootfsOverlayInfo {
	overlayInfo := &CubeRootfsOverlayInfo{}
	for _, dir := range ovlShare {
		overlayInfo.VirtiofsLowerDir = append(overlayInfo.VirtiofsLowerDir, dir.MountPath)
		overlayInfo.HostLowerDir = append(overlayInfo.HostLowerDir, dir.SharePath)
	}
	return overlayInfo
}

func (i *CubeRootfsInfo) ShareDirs() []string {
	var shareDir []string
	for _, m := range i.Mounts {
		if m.HostSource != "" {
			shareDir = append(shareDir, m.HostSource)
		}
	}
	if i.Overlay != nil && len(i.Overlay.HostLowerDir) > 0 {
		shareDir = append(shareDir, i.Overlay.HostLowerDir...)
	}
	return shareDir
}

func GenPropagationVirtioDirs() string {

	return fmt.Sprintf(`[{"name":"%s"},{"name":"%s"}]`, constants.PropagationVirtioRo, constants.PropagationVirtioRw)
}

func GenPropagationContainerDirs() string {
	const s = `[{"name":"%s","container_dir":"%s"},{"name":"%s","container_dir":"%s"}]`
	return fmt.Sprintf(s, constants.PropagationVirtioRo, constants.PropagationContainerDirRo,
		constants.PropagationVirtioRw, constants.PropagationContainerDirRw)
}

func GenPropagationContainerUmounts() string {
	const s = `[{"name":"%s","container_dir":"%s"},{"name":"%s","container_dir":"%s"}]`
	return fmt.Sprintf(s, constants.PropagationVirtioRo, constants.PropagationContainerDirRo,
		constants.PropagationVirtioRw, constants.PropagationContainerDirRw)
}
