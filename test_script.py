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

    def test_arch_mapping(self):
        for arch, asset in [('x86_64','amd64'),('amd64','amd64'),('aarch64','aarch64'),('arm64','aarch64')]:
            r=self.run_sh(f'select_arch {arch}; select_release 5; printf "%s %s" "$ASSET_ARCH" "$OFFICIAL_SHA256"')
            self.assertEqual(r.returncode,0)
            selected, digest=r.stdout.split()
            self.assertEqual(selected,asset)
            self.assertEqual(len(digest),64)
        for arch in ('armv7l','i686','riscv64'):
            self.assertNotEqual(self.run_sh(f'select_arch {arch}').returncode,0)

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
select_arch x86_64
select_release 5
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
select_arch x86_64
installed_major() { echo 5; }
prepare_binary() { WORK=$(mktemp -d); printf new > "$WORK/snell-server"; }
owned_pids() { :; }; action() { :; }
wait_healthy() { [ "$(cat "$BASE/snell-server")" = old ]; }
update_cmd
'''.replace('ROOT',d))
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual((pathlib.Path(d)/'bin/snell-server').read_text(),'old')
            self.assertIn('已恢复原服务',r.stdout)
            self.assertEqual((pathlib.Path(d)/'server.conf').read_text(),'listen = 0.0.0.0:20004\n')


class VersionSwitchTests(unittest.TestCase):
    def run_sh(self, body):
        return subprocess.run(['sh', '-c', LIB+'\n'+body],text=True,capture_output=True,timeout=10)

    def test_release_matrix(self):
        hashes=set()
        for arch in ('x86_64','aarch64'):
            for major,version in ((5,'5.0.1'),(6,'6.0.0')):
                r=self.run_sh(f'select_arch {arch}; select_release {major}; printf "%s %s" "$VERSION" "$OFFICIAL_SHA256"')
                self.assertEqual(r.returncode,0)
                v,h=r.stdout.split(); self.assertEqual(v,version)
                self.assertRegex(h,r'^[0-9a-f]{64}$'); hashes.add(h)
        self.assertEqual(len(hashes),4)
        self.assertNotEqual(self.run_sh('select_arch x86_64; select_release 7').returncode,0)

    def test_detected_ipv4_validation(self):
        for v in ('1.2.3.4','203.0.113.1'):
            self.assertEqual(self.run_sh(f'valid_ipv4 "{v}"').returncode,0)
        for v in ('1.2.3','1.2.3.999','a.b.c.d','1..2.3','1.2.3.4.5','<html>',''):
            self.assertNotEqual(self.run_sh(f'valid_ipv4 "{v}"').returncode,0)

    def test_convert_roundtrip_keeps_psk_port_dns(self):
        with tempfile.TemporaryDirectory() as d:
            conf=pathlib.Path(d)/'input-v5.conf'
            conf.write_text('[snell-server]\nlisten = 0.0.0.0:20005\npsk = test-secret\ndns = 1.1.1.1\nobfs = off\n')
            r=self.run_sh(f'CONF={conf}; WORK={d}; MAJOR=6; trap - EXIT; convert_config')
            self.assertEqual(r.returncode,0,r.stderr)
            text=(pathlib.Path(d)/'server.conf').read_text()
            self.assertIn('mode = default',text); self.assertNotIn('obfs =',text)
            self.assertIn('psk = test-secret',text); self.assertIn('dns = 1.1.1.1',text)
            # Separate input and output as in the real staging workflow.
            conf2=pathlib.Path(d)/'input.conf'; conf2.write_text(text)
            r=self.run_sh(f'CONF={conf2}; WORK={d}; MAJOR=5; trap - EXIT; convert_config')
            self.assertEqual(r.returncode,0,r.stderr)
            text=(pathlib.Path(d)/'server.conf').read_text()
            self.assertIn('obfs = off',text); self.assertNotIn('mode =',text)
            self.assertIn('listen = 0.0.0.0:20005',text)

    def test_obfs_rejected_before_switch(self):
        with tempfile.TemporaryDirectory() as d:
            conf=pathlib.Path(d)/'input.conf'; conf.write_text('obfs = tls\n')
            r=self.run_sh(f'CONF={conf}; WORK={d}; MAJOR=6; trap - EXIT; convert_config')
            self.assertNotEqual(r.returncode,0)
            self.assertEqual(conf.read_text(),'obfs = tls\n')

    def transaction_case(self, fault, running=True):
        with tempfile.TemporaryDirectory() as d:
            setup='''
BASE="ROOT/bin"; CONF="ROOT/input.conf"; META="ROOT/client.conf"; BACKUPS="ROOT/backups"
mkdir -p "$BASE"; printf old > "$BASE/snell-server"; chmod 755 "$BASE/snell-server"
printf 'listen = 0.0.0.0:20005\npsk = test-secret\nobfs = off\n' > "$CONF"
printf 'host = example.com\nport = 20005\n' > "$META"
lock() { :; }; unit_exists() { :; }; deps() { :; }
select_arch x86_64
installed_major() { echo 5; }
prepare_binary() { WORK=$(mktemp -d); printf new > "$WORK/snell-server"; }
owned_pids() { :; }; install_self() { :; }; export_cmd() { :; }
SNELL_YES=1
'''.replace('ROOT',d)
            action='action() { :; }' if running else 'action() { [ "$1" != status ]; }'
            r=self.run_sh(setup+'\n'+action+'\n'+fault+'\nchange_release switch 6')
            return r,(pathlib.Path(d)/'bin/snell-server').read_text(),(pathlib.Path(d)/'input.conf').read_text(),(pathlib.Path(d)/'client.conf').read_text()

    def test_switch_success_preserves_metadata(self):
        r,b,c,m=self.transaction_case('wait_healthy() { :; }')
        self.assertEqual(r.returncode,0,r.stderr); self.assertEqual(b,'new')
        self.assertIn('mode = default',c); self.assertIn('psk = test-secret',c)
        self.assertEqual(m,'host = example.com\nport = 20005\n')

    def test_switch_start_failure_rolls_back_config_and_binary(self):
        r,b,c,_=self.transaction_case('wait_healthy() { [ "$(cat "$BASE/snell-server")" = old ]; }')
        self.assertNotEqual(r.returncode,0); self.assertEqual(b,'old')
        self.assertIn('obfs = off',c); self.assertNotIn('mode =',c)

    def test_switch_signal_rolls_back(self):
        r,b,c,_=self.transaction_case('wait_healthy() { if [ "$(cat "$BASE/snell-server")" = new ]; then kill -TERM $$; else return 0; fi; }')
        self.assertNotEqual(r.returncode,0); self.assertEqual(b,'old')
        self.assertIn('obfs = off',c)

    def test_stopped_switch_does_not_start(self):
        r,b,c,_=self.transaction_case('wait_healthy() { exit 99; }; action() { case "$1" in status) return 1;; start) exit 98;; *) return 0;; esac; }',False)
        self.assertEqual(r.returncode,0,r.stderr); self.assertEqual(b,'new')
        self.assertIn('mode = default',c)

    def test_cancel_before_dependencies(self):
        r=self.run_sh('lock() { :; }; unit_exists() { :; }; installed_major() { echo 5; }; deps() { exit 99; }; BASE=/bin; CONF=/etc/hosts; select_arch x86_64; change_release switch 6 <<EOF\nNO\nEOF')
        self.assertNotEqual(r.returncode,99)
        self.assertNotEqual(r.returncode,0)

class InteractionTests(unittest.TestCase):
    def test_install_one_port_auto_host(self):
        for major in (5,6):
            with tempfile.TemporaryDirectory() as d:
                # Redirect every service path before evaluating the library.
                lib=LIB.replace('/usr/local/lib/snell-v5',d+'/bin').replace('/etc/snell-v5',d+'/etc')
                body='''
select_arch x86_64
MANAGER=openrc
lock() { :; }; unit_exists() { return 1; }; deps() { :; }
port_busy() { return 1; }; curl() { printf 203.0.113.7; }
prepare_binary() { WORK=$(mktemp -d); printf fake > "$WORK/snell-server"; }
write_unit() { :; }; action() { :; }; wait_healthy() { :; }
testbin=$(dirname "$BASE")/test-bin
mkdir -p "$testbin"
printf '#!/bin/sh\nexit 0\n' > "$testbin/rc-update"
chmod 755 "$testbin/rc-update"
PATH="$testbin:$PATH"
install_self() { :; }; export_cmd() { :; }
install_cmd
'''
                r=subprocess.run(['sh','-c',lib+'\n'+body],input=f'{major}\n20005\n',capture_output=True,text=True)
                self.assertEqual(r.returncode,0,r.stderr)
                meta=(pathlib.Path(d)/'etc/client.conf').read_text()
                self.assertEqual(meta,'host = 203.0.113.7\nport = 20005\n')
                conf=(pathlib.Path(d)/'etc/server.conf').read_text()
                self.assertIn('listen = 0.0.0.0:20005',conf)
                self.assertEqual('mode = default' in conf,major==6)
                self.assertNotIn('请填写公网',r.stdout)

    def test_reject_different_public_port(self):
        with tempfile.TemporaryDirectory() as d:
            body=f'''BASE={d}/bin; CONF={d}/etc/server.conf
lock() {{ :; }}; unit_exists() {{ return 1; }}; deps() {{ exit 99; }}
select_arch x86_64
SNELL_VERSION=5; SNELL_PORT=20005; SNELL_PUBLIC_PORT=30005
install_cmd
'''
            r=subprocess.run(['sh','-c',LIB+'\n'+body],capture_output=True,text=True)
            self.assertNotEqual(r.returncode,0); self.assertNotEqual(r.returncode,99)
            self.assertIn('相同端口',r.stderr)

    def test_export_tracks_actual_binary_major(self):
        for major in (5,6):
            with tempfile.TemporaryDirectory() as d:
                c=pathlib.Path(d)/'config'; c.write_text('psk = test-key\nmode = default\n')
                m=pathlib.Path(d)/'meta'; m.write_text('host = example.com\nport = 20005\n')
                r=subprocess.run(['sh','-c',LIB+f'\nCONF={c}; META={m}; root_only() {{ :; }}; installed_major() {{ echo {major}; }}; export_cmd'],capture_output=True,text=True)
                self.assertEqual(r.returncode,0,r.stderr)
                self.assertIn(f'version={major}',r.stdout)
                self.assertEqual('mode=default' in r.stdout,major==6)

class LockLifecycleTests(unittest.TestCase):
    def harness(self, d):
        p=pathlib.Path(d)/'manager.sh'
        body='''
LOCK="ROOT/lock"
root_only() { :; }
if [ "${1:-}" = __locked ]; then
 shift
 case "$1" in
   fail) exit 2;;
   killed) kill -KILL $$;;
   hold) echo READY; read -r release;;
   daemon) (sleep 1) >/dev/null 2>&1 &;;
   replace) cp "$0" "$0.new"; mv "$0.new" "$0";;
 esac
 exit 0
fi
with_lock "$@"
'''.replace('ROOT',d)
        p.write_text(LIB+'\n'+body)
        return p

    def call(self,p,cmd):
        return subprocess.run(['sh',str(p),cmd],capture_output=True,text=True,timeout=5)

    def test_repeated_success_failure_release(self):
        with tempfile.TemporaryDirectory() as d:
            p=self.harness(d)
            for cmd in ('ok','fail','ok','killed','ok'):
                r=self.call(p,cmd)
                self.assertEqual(r.returncode==0,cmd=='ok',r.stderr)

    def test_legacy_empty_directory_is_not_stale_kernel_lock(self):
        with tempfile.TemporaryDirectory() as d:
            p=self.harness(d); (pathlib.Path(d)/'lock').mkdir()
            self.assertEqual(self.call(p,'ok').returncode,0)
            self.assertTrue((pathlib.Path(d)/'lock').is_dir())

    def test_active_operation_is_blocked(self):
        with tempfile.TemporaryDirectory() as d:
            p=self.harness(d)
            proc=subprocess.Popen(['sh',str(p),'hold'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                self.assertEqual(proc.stdout.readline().strip(),'READY')
                r=self.call(p,'ok'); self.assertNotEqual(r.returncode,0)
                self.assertIn('确实正在运行',r.stderr)
            finally: proc.communicate('release\n',timeout=5)
            self.assertEqual(self.call(p,'ok').returncode,0)

    def test_daemon_does_not_inherit_lock(self):
        with tempfile.TemporaryDirectory() as d:
            p=self.harness(d)
            self.assertEqual(self.call(p,'daemon').returncode,0)
            self.assertEqual(self.call(p,'ok').returncode,0)

    def test_self_replacement_releases_lock(self):
        with tempfile.TemporaryDirectory() as d:
            p=self.harness(d)
            self.assertEqual(self.call(p,'replace').returncode,0)
            self.assertEqual(self.call(p,'ok').returncode,0)

    def test_actual_menu_repeated_switch(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'menu.sh'
            p.write_text(LIB+'''\nroot_only() { :; }; platform() { :; }
switch_cmd() { lock; echo SWITCH_REACHED; }
'''+f'LOCK={d}/lock\n'+ 'main "$@"\n')
            r=subprocess.run(['sh',str(p)],input='10\n10\n0\n',capture_output=True,text=True,timeout=5)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(r.stdout.count('SWITCH_REACHED'),2)

if __name__=='__main__': unittest.main(verbosity=2)
