import importlib.util
import pathlib
import tomllib
import unittest

spec = importlib.util.spec_from_file_location("cube_containerd", pathlib.Path(__file__).with_name("containerd.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ContainerdConfigTest(unittest.TestCase):
    def source(self, plugin, version):
        return f'''version = {version}
root = '/custom/root'
state = '/custom/state'
required_plugins = ['io.containerd.grpc.v1.cri']
[grpc]
address = '/custom/containerd.sock'
[plugins.'{plugin}'.cni]
conf_dir = '/custom/cni'
[plugins.'{plugin}'.containerd]
default_runtime_name = 'runc'
[plugins.'{plugin}'.containerd.runtimes.runc]
runtime_type = 'io.containerd.runc.v2'
[plugins.'{plugin}'.containerd.runtimes.runc.options]
SystemdCgroup = true
'''

    def test_version_detection(self):
        for version, expected in [('v1.7.28-tke.3', '1.7'), ('v2.0.11', '2'), ('v2.3.4', '2')]:
            self.assertEqual(module.family('containerd github.com/containerd/containerd ' + version), expected)
        for version in ('v1.6.33', 'v1.70.1', 'v3.0.0', 'unknown'):
            with self.assertRaises(ValueError):
                module.family(version)

    def test_both_config_families_preserve_node_settings_and_are_idempotent(self):
        for major, plugin, version, key in [('1.7', module.CRI17, 2, 'sandbox_mode'), ('2', module.CRI2, 3, 'sandboxer'), ('2', module.CRI2, 4, 'sandboxer')]:
            source = self.source(plugin, version)
            result = module.configure(source, major)
            parsed = tomllib.loads(result)
            self.assertEqual(parsed['plugins'][plugin]['containerd']['runtimes']['cube'][key], 'shim')
            cube = parsed['plugins'][plugin]['containerd']['runtimes']['cube']
            self.assertTrue(cube['privileged_without_host_devices'])
            self.assertTrue(cube['privileged_without_host_devices_all_devices_allowed'])
            if major == '2':
                self.assertEqual(parsed['plugins'][module.SHIM_MANAGER]['env'], ['CUBE_ALLOW_PRIVILEGED=true'])
            self.assertEqual(parsed['root'], '/custom/root')
            self.assertEqual(parsed['state'], '/custom/state')
            self.assertEqual(parsed['grpc']['address'], '/custom/containerd.sock')
            self.assertEqual(parsed['plugins'][plugin]['cni']['conf_dir'], '/custom/cni')
            self.assertTrue(parsed['plugins'][plugin]['containerd']['runtimes']['runc']['options']['SystemdCgroup'])
            self.assertEqual(module.configure(result, major), result)
            if major == '2':
                self.assertEqual(parsed['required_plugins'], ['io.containerd.cri.v1.images', module.CRI2])

    def test_replaces_owned_cube_sections_without_removing_adjacent_runtime(self):
        source = self.source(module.CRI17, 2) + f'''
[plugins."{module.CRI17}".containerd.runtimes.cube]
runtime_type = 'io.containerd.cube.rs'
sandbox_mode = 'podsandbox'
[plugins."{module.CRI17}".containerd.runtimes.cube.options]
[plugins."{module.CRI17}".containerd.runtimes.other]
runtime_type = 'io.containerd.runc.v2'
'''
        result = tomllib.loads(module.configure(source, '1.7'))['plugins'][module.CRI17]['containerd']['runtimes']
        self.assertIn('other', result)
        self.assertNotIn('options', result['cube'])
        with self.assertRaises(ValueError):
            module.configure(source.replace("runtime_type = 'io.containerd.cube.rs'", "runtime_type = 'io.containerd.other.v2'"), '1.7')

    def test_privileged_switch_replaces_stale_values_and_preserves_shim_settings(self):
        source = self.source(module.CRI2, 3) + f'''
[plugins.'{module.SHIM_MANAGER}']
env = ['CUBE_ALLOW_PRIVILEGED=false', 'OTHER=value', 'CUBE_ALLOW_PRIVILEGED=true']
socket_dir = '/custom/shim'
'''
        result = module.configure(source, '2')
        manager = tomllib.loads(result)['plugins'][module.SHIM_MANAGER]
        self.assertEqual(manager['env'], ['OTHER=value', 'CUBE_ALLOW_PRIVILEGED=true'])
        self.assertEqual(manager['socket_dir'], '/custom/shim')
        self.assertEqual(module.configure(result, '2'), result)

    def test_preserves_launch_overrides(self):
        for args in [['-c', '/old/config', '--root', '/custom/root', '--state=/custom/state'], ['--config=/old/config', '-a', '/custom/socket']]:
            result = module.with_config(args, '/new/config')
            self.assertEqual(result[:2], ['--config', '/new/config'])
            self.assertNotIn('/old/config', result)
            self.assertEqual(module.option(result, ('--root',), None), module.option(args, ('--root',), None))
            self.assertEqual(module.option(result, ('--address', '-a'), None), module.option(args, ('--address', '-a'), None))
        self.assertEqual(module.unit_arg('/path/$name%value'), '"/path/$$name%%value"')
        self.assertEqual(module.option(['-c', '/first', '--config=/last'], ('--config', '-c'), None), '/last')

    def test_does_not_reimport_17_source_and_keeps_external_imports(self):
        self.assertEqual(module.relocate_imports(['/etc/containerd/config.toml', 'extra.toml', '/etc/containerd/conf.d/*.toml'], pathlib.Path('/etc/containerd/config.toml')), ['/etc/containerd/extra.toml', '/etc/containerd/conf.d/*.toml'])


if __name__ == '__main__':
    unittest.main()
