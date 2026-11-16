#!/usr/bin/env python3
"""Offline tests: no root, network, packages or host services touched."""
import pathlib, subprocess, tempfile, unittest
SOURCE = pathlib.Path(__file__).with_name('snell-v5.sh').read_text()
LIB = SOURCE.rsplit('main "$@"', 1)[0]

class ScriptTests(unittest.TestCase):
    def run_sh(self, body):
        return subprocess.run(['sh', '-c', LIB + '\n' + body], text=True, capture_output=True)

    def test_syntax(self):
        subprocess.run(['sh', '-n', str(pathlib.Path(__file__).with_name('snell-v5.sh'))], check=True)

    def test_ports(self):
        for port in ('1024', '20005', '60005', '65535'):
            self.assertEqual(self.run_sh(f'valid_port {port}').returncode, 0)
        for port in ('0','22','1023','65536','00080','-1','1x','999999999999999999999',''):
            self.assertNotEqual(self.run_sh("valid_port '" + port + "'").returncode, 0)

    def test_host_injection_rejected(self):
        for host in ('example.com', '192.0.2.10', '2001:db8::1'):
            self.assertEqual(self.run_sh(f"valid_host '{host}'").returncode, 0)
        for host in ('', 'a,b', 'a b', 'a;id', '$(id)', '[::1]'):
            self.assertNotEqual(self.run_sh(f"valid_host '{host}'").returncode, 0)

    def test_port_check_both_protocols(self):
        r=self.run_sh('ss() { case "$*" in *-lnu*) echo occupied;; esac; }; port_busy 20004')
        self.assertEqual(r.returncode, 0)
        self.assertNotEqual(self.run_sh('ss() { :; }; port_busy 20004').returncode, 0)
        self.assertEqual(self.run_sh('ss() { return 1; }; port_busy 20004').returncode, 0)

    def test_pid_must_own_socket(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'server.conf'; p.write_text('listen = 0.0.0.0:20004\n')
            setup=f'CONF={p}; owned_pids() {{ echo 123; }}; '
            r=self.run_sh(setup+'ss() { echo \'users:(("loader",pid=999,fd=1))\'; }; healthy')
            self.assertNotEqual(r.returncode, 0)
            r=self.run_sh(setup+'ss() { echo \'users:(("loader",pid=123,fd=1))\'; }; healthy')
            self.assertEqual(r.returncode, 0)

    def test_hash_failure_stops_before_execution(self):
        r=self.run_sh('''
MANAGER=systemd
curl() { :; }
unzip() { printf fake > "$WORK/snell-server"; }
prepare_binary
printf SHOULD_NOT_REACH
''')
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('SHOULD_NOT_REACH',r.stdout)
        self.assertIn('SHA-256',r.stderr)

    def test_update_failure_rolls_back(self):
        with tempfile.TemporaryDirectory() as d:
            r=self.run_sh('''
BASE="ROOT/bin"; CONF="ROOT/server.conf"; META="ROOT/client.conf"; BACKUPS="ROOT/backups"
mkdir -p "$BASE"; printf old > "$BASE/snell-server"; chmod 755 "$BASE/snell-server"
printf 'listen = 0.0.0.0:20004\n' > "$CONF"
lock() { :; }; unit_exists() { return 0; }; deps() { :; }
prepare_binary() { WORK=$(mktemp -d); printf new > "$WORK/snell-server"; }
owned_pids() { echo 123; }; action() { :; }
wait_healthy() { [ "$(cat "$BASE/snell-server")" = old ]; }
update_cmd
'''.replace('ROOT',d))
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual((pathlib.Path(d)/'bin/snell-server').read_text(),'old')
            self.assertIn('已恢复原服务',r.stderr)

if __name__=='__main__': unittest.main(verbosity=2)
