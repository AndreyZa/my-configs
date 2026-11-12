#!/usr/bin/env python3
"""Exercise personal-settings migration without touching the user's dotfiles."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
HELPER = REPO / "lib/migrate_zshrc.py"
BASH = os.environ.get("BASH", "/bin/bash")


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="my-configs-migration-", dir=os.getenv("TMPDIR", "/tmp"))
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.old = self.root / "old.zshrc"
        self.template = self.root / "new.zshrc"
        self.baseline = self.root / "baseline.zshrc"
        self.local = self.root / "existing.local"
        self.output = self.root / "merged.local"
        self.template.write_text("# New shared configuration\n")
        self.target = self.root / "user files"
        self.target.mkdir()
        self.state = self.target / ".local/state/my-configs"
        (self.state / "templates").mkdir(parents=True)

    def helper(self, old, *, baseline=None, local=None, success=True):
        self.old.write_text(old)
        if baseline is not None:
            self.baseline.write_text(baseline)
        if local is not None:
            self.local.write_text(local)
        result = subprocess.run(
            [sys.executable, str(HELPER), str(self.old), str(self.template), str(self.baseline), str(self.local), str(self.output)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(self.output.is_file())
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def shell(self, script, *args):
        env = os.environ.copy()
        env.update(HISTFILE="/dev/null", KUBECONFIG="/dev/null", CHECKPOINT_DISABLE="1", XDG_CACHE_HOME=str(self.root / "cache"))
        result = subprocess.run(
            ["zsh", "-dfc", script, "--", *map(str, args)], env=env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def load_local(self, checks):
        return self.shell(
            '_MY_CONFIGS_LOCAL_PHASE=early; source "$1"; unset _MY_CONFIGS_LOCAL_PHASE; source "$1";\n' + checks,
            self.output,
        )

    def install(self, *, replace=True):
        script = r'''
set -euo pipefail
BOOTSTRAP_ROOT=$1
source "$BOOTSTRAP_ROOT/lib/bootstrap.sh"
MC_TARGET=$2
MC_STATE="$MC_TARGET/.local/state/my-configs"
MC_REPLACE=$4
MC_BACKUP_DIR=''
MC_CONFLICTS=0
MC_UPDATE=0
MC_TARGET_EXPLICIT=1
mc_install_config "$3" "$MC_TARGET/.zshrc" zshrc
printf 'migration-conflicts=%s\n' "$MC_CONFLICTS"
'''
        return subprocess.run(
            [BASH, "-c", script, "--", str(REPO), str(self.target), str(self.template), "1" if replace else "0"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45,
        )

    def recovery_fixture(self):
        self.template.write_bytes((REPO / "zshrc").read_bytes())
        (self.target / ".zshrc").write_bytes(self.template.read_bytes())
        (self.state / "templates/zshrc").write_bytes(self.template.read_bytes())
        (self.target / ".p10k.zsh").write_text("# Existing prompt remains untouched.\n")

    def recovery(self, backup=None):
        args = [BASH, str(REPO / "setup.sh"), "--restore-local"]
        if backup is not None:
            args.append(str(backup))
        args += ["--target-dir", str(self.target), "--skip-packages", "--no-fonts", "--no-chsh"]
        return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)

    def file_snapshot(self):
        return {p.relative_to(self.target): (p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_mode)
                for p in self.target.rglob("*") if p.is_file()}

    def test_functions_aliases_environment_and_path_survive(self):
        self.helper(r'''
export GOROOT=/opt/personal-go
export GOPATH="$HOME/personal-go"
export PATH="$GOPATH/bin:$GOROOT/bin:$PATH"
export EDITOR=nano
alias ksn='kubens'
alias wslc='wslc.exe'
_aiup_report() {
  case "$1" in
    success) print -r -- 'updated successfully' ;;
    *) print -r -- 'try later' ;;
  esac
}
aiup() {
  if [[ $# == 0 ]]; then
    _aiup_report success
  else
    _aiup_report "$1"
  fi
}
''')
        output = self.load_local(r'''
[[ $EDITOR == nano && $GOROOT == /opt/personal-go && $GOPATH == "$HOME/personal-go" ]] || exit 1
[[ $path[1] == "$GOPATH/bin" && $path[2] == "$GOROOT/bin" ]] || exit 2
[[ $aliases[ksn] == kubens && $aliases[wslc] == wslc.exe ]] || exit 3
aiup
''')
        self.assertEqual(output, "updated successfully\n")

    def test_installation_never_executes_old_or_existing_configuration(self):
        marker = self.root / "executed"
        command = "print should-not-run >> " + shlex.quote(str(marker))
        self.helper(
            command + '\nexport PERSONAL_VALUE="$(' + command + ')"\n',
            local=command + "\n",
        )
        self.assertFalse(marker.exists())

    def test_existing_local_code_retains_precedence_and_bytes(self):
        existing = "# User-owned local settings.\nalias shared_name='from-local'\nlocal_tool() { print -r -- local; }\n"
        self.helper("alias shared_name='from-old'\nalias moved='still-here'\n", local=existing)
        self.assertIn(existing, self.output.read_text())
        self.assertEqual(self.local.read_text(), existing)
        self.load_local("[[ $aliases[shared_name] == from-local && $aliases[moved] == still-here ]] || exit 1\nlocal_tool >/dev/null")

    def test_early_settings_are_not_replaced_by_identical_late_local_code(self):
        initialization = 'export PERSONAL_EARLY_SETTING=required\nexport PATH="/opt/personal-cli:$PATH"\n'
        self.helper(initialization + 'source "$ZSH/oh-my-zsh.sh"\nalias personal_late=available\n',
                    local=initialization)
        self.shell(r'''
_MY_CONFIGS_LOCAL_PHASE=early
source "$1"
[[ $PERSONAL_EARLY_SETTING == required && $path[1] == /opt/personal-cli ]] || exit 1
unset _MY_CONFIGS_LOCAL_PHASE
source "$1"
[[ $aliases[personal_late] == available ]] || exit 2
''', self.output)

    def test_managed_template_is_not_copied_into_local(self):
        baseline = "# shared baseline\nexport SHARED_SETTING=old-default\nalias ordinary='old-shared'\n"
        self.template.write_text("# shared next version\nexport SHARED_SETTING=new-default\nalias ordinary='new-shared'\n")
        self.helper(baseline + "alias personal='kept'\n", baseline=baseline)
        content = self.output.read_text()
        self.assertNotIn("SHARED_SETTING", content)
        self.assertNotIn("old-shared", content)
        self.load_local("[[ $aliases[personal] == kept ]] || exit 1")

    def test_edited_managed_alias_is_carried_forward(self):
        baseline = "alias ordinary='shared-default'\n"
        self.template.write_text(baseline)
        self.helper("alias ordinary='my-preference'\n", baseline=baseline)
        self.load_local("[[ $aliases[ordinary] == my-preference ]] || exit 1")

    def test_repeated_assignments_keep_the_final_original_value(self):
        self.helper("export PERSONAL_VALUE=one\nexport PERSONAL_VALUE=two\nexport PERSONAL_VALUE=one\n")
        self.load_local("[[ $PERSONAL_VALUE == one ]] || exit 1")

    def test_repeated_statements_within_one_config_are_not_deduplicated(self):
        self.helper("(( PERSONAL_COUNTER += 1 ))\n(( PERSONAL_COUNTER += 1 ))\n")
        self.load_local("[[ $PERSONAL_COUNTER == 2 ]] || exit 1")

    def test_restoring_a_baseline_value_later_in_the_file_remains_effective(self):
        baseline = "alias ordinary='shared-default'\n"
        self.template.write_text(baseline)
        self.helper(baseline + "alias ordinary='custom'\n" + baseline, baseline=baseline)
        self.load_local("[[ $aliases[ordinary] == shared-default ]] || exit 1")

    def test_personal_alias_can_refer_to_the_config_file(self):
        self.helper("alias editzsh='nano ~/.zshrc'\nalias editlocal='nano ~/.zshrc.local'\n")
        self.load_local("[[ $aliases[editzsh] == 'nano ~/.zshrc' && $aliases[editlocal] == 'nano ~/.zshrc.local' ]] || exit 1")

    def test_framework_setting_with_late_dependency_preserves_active_config(self):
        old = 'CUSTOM_THEME=robbyrussell\nZSH_THEME="$CUSTOM_THEME"\n'
        (self.target / ".zshrc").write_text(old)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.target / ".zshrc").read_text(), old)
        self.assertFalse((self.target / ".zshrc.local").exists())

    def test_independent_framework_initialization_remains_supported(self):
        self.helper('export ZSH="$HOME/.oh-my-zsh"\nexport ZSH_CUSTOM="$ZSH/custom"\nZSH_THEME=robbyrussell\n')
        self.shell(r'''
_MY_CONFIGS_LOCAL_PHASE=early
source "$1"
[[ $ZSH == "$HOME/.oh-my-zsh" && $ZSH_CUSTOM == "$ZSH/custom" && $ZSH_THEME == robbyrussell ]] || exit 1
''', self.output)

    def test_second_migration_merges_new_commands_without_duplicates(self):
        old = "alias first='one'\n"
        self.helper(old, local="alias existing='local'\n")
        first = self.output.read_text()
        self.helper(old, local=first)
        self.assertEqual(self.output.read_text(), first)
        self.helper(self.template.read_text() + "alias second='two'\n", baseline=self.template.read_text(), local=first)
        merged = self.output.read_text()
        self.assertEqual(merged.count("alias first='one'"), 1)
        self.assertEqual(merged.count("alias second='two'"), 1)
        self.assertEqual(merged.count("alias existing='local'"), 1)
        self.load_local("[[ $aliases[first] == one && $aliases[second] == two && $aliases[existing] == local ]] || exit 1")

    def test_existing_migrated_preference_wins_over_older_recovered_value(self):
        self.helper("alias preferred='current'\n")
        current = self.output.read_text()
        self.helper("alias preferred='older-backup'\n", local=current)
        self.load_local("[[ $aliases[preferred] == current ]] || exit 1")

    def test_edited_generated_layout_is_preserved_instead_of_discarded(self):
        self.helper("alias first='one'\n")
        current = self.output.read_text()
        edited = current.replace("# my-configs: early end\n", "# my-configs: early end\nalias inserted='must-survive'\n", 1)
        self.assertNotEqual(current, edited)
        self.helper("alias second='two'\n", local=edited, success=False)
        self.assertEqual(self.local.read_text(), edited)

    def test_loader_guard_side_effect_is_neither_executed_nor_discarded(self):
        marker = self.root / "guard-executed"
        old = ('if [[ -r "$(print guard > ' + shlex.quote(str(marker))
               + '; print -r -- "$ZSH")/oh-my-zsh.sh" ]]; then\n'
               + '  source "$ZSH/oh-my-zsh.sh"\nfi\n')
        self.helper(old, success=False)
        self.assertFalse(marker.exists())

    def test_config_name_in_guard_does_not_hide_a_personal_source(self):
        personal = self.root / "personal.zsh"
        personal.write_text("alias personal_source='required'\n")
        old = ('[[ -f "$HOME/.zshrc" ]] && source ' + shlex.quote(str(personal)) + "\n")
        self.helper(old, success=False)
        self.assertEqual(self.old.read_text(), old)

    def test_heredoc_and_multiline_function_remain_one_block(self):
        self.helper(r'''
personal_text() {
  cat <<'PERSONAL_END'
if then } ; alias x=y
source "$ZSH/oh-my-zsh.sh"
PERSONAL_END
}
function multiline_name
{
  print -r -- "function body"
}
export PERSONAL_WORDS="one "\
"two"
''')
        self.assertEqual(
            self.load_local('personal_text; multiline_name; print -r -- "$PERSONAL_WORDS"'),
            'if then } ; alias x=y\nsource "$ZSH/oh-my-zsh.sh"\nfunction body\none two\n',
        )

    def test_literal_carriage_returns_keep_their_runtime_value(self):
        self.helper('personal_literal() { print -rn -- "one\r\ntwo"; }\n')
        result = subprocess.run(['zsh', '-dfc', 'source "$1"; personal_literal', '--', str(self.output)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"one\r\ntwo")

    def test_local_source_does_not_recurse_and_personal_source_is_retained(self):
        personal = self.root / "personal.zsh"
        personal.write_text("alias sourced_personal='present'\n")
        self.helper(
            '[[ ! -r "${ZDOTDIR:-$HOME}/.zshrc.local" ]] || source "${ZDOTDIR:-$HOME}/.zshrc.local"\n'
            + "source " + shlex.quote(str(personal)) + "\nalias direct_personal='present'\n"
        )
        self.load_local("[[ $aliases[sourced_personal] == present && $aliases[direct_personal] == present ]] || exit 1")

    def test_preparation_does_not_modify_active_or_local_configuration(self):
        old = "alias preserved='old-value'\n"
        local = "alias local_preserved='local-value'\n"
        (self.target / ".zshrc").write_text(old)
        (self.target / ".zshrc.local").write_text(local)
        result = self.install(replace=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.target / ".zshrc").read_text(), old)
        self.assertEqual((self.target / ".zshrc.local").read_text(), local)
        self.assertTrue((self.target / ".zshrc.my-configs-new").is_file())
        self.assertFalse(list(self.state.glob("backup-*")))

    def test_replacement_backs_up_both_files_and_rerun_is_a_noop(self):
        old = "alias preserved='old-value'\n"
        local = "alias preserved='local-value'\n"
        (self.target / ".zshrc").write_text(old)
        (self.target / ".zshrc.local").write_text(local)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.target / ".zshrc").read_bytes(), self.template.read_bytes())
        backups = list(self.state.glob("backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "zshrc").read_text(), old)
        self.assertEqual((backups[0] / "zshrc.local").read_text(), local)
        migrated = self.target / ".zshrc.local"
        self.assertIn(local, migrated.read_text())
        before = {p.relative_to(self.target): (p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_mode) for p in self.target.rglob("*") if p.is_file()}
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        after = {p.relative_to(self.target): (p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_mode) for p in self.target.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_bad_syntax_keeps_active_files_and_does_not_print_their_contents(self):
        old = "export PERSONAL_TEST_SECRET='do-not-print-this-value\n"
        local = "alias existing='untouched'\n"
        (self.target / ".zshrc").write_text(old)
        (self.target / ".zshrc.local").write_text(local)
        result = self.install()
        self.assertEqual((self.target / ".zshrc").read_text(), old)
        self.assertEqual((self.target / ".zshrc.local").read_text(), local)
        self.assertNotIn("do-not-print-this-value", result.stdout + result.stderr)

    def test_mixed_framework_and_personal_block_keeps_active_configuration(self):
        old = 'if [[ -r "$ZSH/oh-my-zsh.sh" ]]; then\n  source "$ZSH/oh-my-zsh.sh"\n  alias critical=preserved\nfi\n'
        (self.target / ".zshrc").write_text(old)
        result = self.install()
        self.assertEqual((self.target / ".zshrc").read_text(), old, result.stdout + result.stderr)
        self.assertFalse((self.target / ".zshrc.local").exists())

    def test_local_symlink_target_is_not_overwritten(self):
        old = "alias must_survive='old'\n"
        (self.target / ".zshrc").write_text(old)
        self.local.write_text("alias external='unchanged'\n")
        (self.target / ".zshrc.local").symlink_to(self.local)
        result = self.install()
        self.assertEqual((self.target / ".zshrc").read_text(), old, result.stdout + result.stderr)
        self.assertTrue((self.target / ".zshrc.local").is_symlink())
        self.assertEqual(self.local.read_text(), "alias external='unchanged'\n")

    def test_early_settings_reach_framework_and_late_aliases_win(self):
        framework = self.target / ".oh-my-zsh"
        custom = framework / "custom"
        custom.mkdir(parents=True)
        (framework / "oh-my-zsh.sh").write_text(r'''
[[ $ZSH_THEME == personal-theme ]] || return 11
[[ ${(j:,:)plugins} == personal-one,personal-two ]] || return 12
[[ $path[1] == /opt/personal-cli ]] || return 13
[[ $HISTSIZE == 70000 && $SAVEHIST == 70000 && $HIST_STAMPS == dd.mm.yyyy ]] || return 14
typeset -g FRAMEWORK_SAW_PERSONAL_SETTINGS=1
alias personal_alias=shared-default
''')
        self.template.write_bytes((REPO / "zshrc").read_bytes())
        old = (
            "export ZSH=" + shlex.quote(str(framework)) + "\n"
            + "export ZSH_CUSTOM=" + shlex.quote(str(custom)) + "\n"
            + 'ZSH_THEME="personal-theme"\nplugins=(personal-one personal-two)\n'
            + 'HISTSIZE=70000\nSAVEHIST=70000\nHIST_STAMPS="dd.mm.yyyy"\n'
            + 'export PATH="/opt/personal-cli:$PATH"\nsource "$ZSH/oh-my-zsh.sh"\n'
            + 'alias personal_alias=my-preference\n'
        )
        (self.target / ".zshrc").write_text(old)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.shell(r'''
ZDOTDIR=$1
source "$ZDOTDIR/.zshrc"
[[ $FRAMEWORK_SAW_PERSONAL_SETTINGS == 1 && $aliases[personal_alias] == my-preference ]] || exit 1
[[ $HISTSIZE == 70000 && $SAVEHIST == 70000 && $HIST_STAMPS == dd.mm.yyyy ]] || exit 2
''', self.target)

    def test_previous_theme_selector_allows_later_personal_theme(self):
        custom = self.target / "custom"
        theme = custom / "themes/powerlevel10k/powerlevel10k.zsh-theme"
        theme.parent.mkdir(parents=True)
        theme.touch()
        baseline = (
            'if [[ -r "$ZSH_CUSTOM/themes/powerlevel10k/powerlevel10k.zsh-theme" ]]; then\n'
            '  ZSH_THEME="powerlevel10k/powerlevel10k"\n'
            'else\n'
            '  ZSH_THEME=""\n'
            "  PROMPT='%n@%m %~ %# '\n"
            'fi\n'
            'source "$ZSH/oh-my-zsh.sh"\n'
        )
        self.helper(baseline + 'ZSH_THEME="personal-theme"\n', baseline=baseline)
        self.shell(r'''
ZSH_CUSTOM=$2
_MY_CONFIGS_LOCAL_PHASE=early
source "$1"
unset _MY_CONFIGS_LOCAL_PHASE
source "$1"
[[ $ZSH_THEME == personal-theme ]] || exit 1
''', self.output, custom)

    def test_previous_theme_selector_allows_edited_personal_theme(self):
        custom = self.target / "custom"
        theme = custom / "themes/powerlevel10k/powerlevel10k.zsh-theme"
        theme.parent.mkdir(parents=True)
        theme.touch()
        baseline = (
            'if [[ -r "$ZSH_CUSTOM/themes/powerlevel10k/powerlevel10k.zsh-theme" ]]; then\n'
            '  ZSH_THEME="powerlevel10k/powerlevel10k"\n'
            'else\n'
            '  ZSH_THEME=""\n'
            "  PROMPT='%n@%m %~ %# '\n"
            'fi\n'
            'source "$ZSH/oh-my-zsh.sh"\n'
        )
        old = baseline.replace('ZSH_THEME="powerlevel10k/powerlevel10k"', 'ZSH_THEME="personal-theme"', 1)
        self.helper(old, baseline=baseline)
        self.shell(r'''
ZSH_CUSTOM=$2
_MY_CONFIGS_LOCAL_PHASE=early
source "$1"
unset _MY_CONFIGS_LOCAL_PHASE
source "$1"
[[ $ZSH_THEME == personal-theme ]] || exit 1
''', self.output, custom)

    def test_previous_plugin_detection_keeps_defaults_before_personal_append(self):
        framework = self.target / ".oh-my-zsh"
        plugin = framework / "plugins/git/git.plugin.zsh"
        plugin.parent.mkdir(parents=True)
        plugin.touch()
        (framework / "oh-my-zsh.sh").write_text(r'''
if [[ ${(j:,:)plugins} != git,personal-plugin ]]; then return 21; fi
typeset -g PERSONAL_PLUGINS_OK=1
''')
        self.template.write_bytes((REPO / "zshrc").read_bytes())
        loader = 'source "$ZSH/oh-my-zsh.sh"\n'
        baseline = (
            'export ZSH="${ZSH:-${ZDOTDIR:-$HOME}/.oh-my-zsh}"\n'
            'export ZSH_CUSTOM="${ZSH_CUSTOM:-$ZSH/custom}"\n'
            'plugins=()\n'
            'if [[ -r "$ZSH/plugins/git/git.plugin.zsh" ]]; then\n'
            '  plugins+=(git)\n'
            'fi\n'
            + loader
        )
        old = baseline.replace(loader, 'plugins+=(personal-plugin)\n' + loader, 1)
        (self.target / ".zshrc").write_text(old)
        (self.state / "templates/zshrc").write_text(baseline)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.shell(r'''
unset ZSH ZSH_CUSTOM plugins
ZDOTDIR=$1
source "$ZDOTDIR/.zshrc"
[[ $PERSONAL_PLUGINS_OK == 1 ]] || exit 1
''', self.target)

    def test_changing_only_zsh_recomputes_default_custom_path(self):
        framework = self.target / "personal-oh-my-zsh"
        framework.mkdir()
        (framework / "oh-my-zsh.sh").write_text(r'''
if [[ $ZSH_CUSTOM != "$ZSH/custom" ]]; then return 22; fi
typeset -g PERSONAL_FRAMEWORK_LOADED=1
''')
        self.template.write_bytes((REPO / "zshrc").read_bytes())
        default_zsh = 'export ZSH="${ZSH:-${ZDOTDIR:-$HOME}/.oh-my-zsh}"\n'
        baseline = (
            default_zsh
            + 'export ZSH_CUSTOM="${ZSH_CUSTOM:-$ZSH/custom}"\n'
            + 'source "$ZSH/oh-my-zsh.sh"\n'
        )
        old = baseline.replace(default_zsh, "export ZSH=" + shlex.quote(str(framework)) + "\n", 1)
        (self.target / ".zshrc").write_text(old)
        (self.state / "templates/zshrc").write_text(baseline)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.shell(r'''
unset ZSH ZSH_CUSTOM
ZDOTDIR=$1
source "$ZDOTDIR/.zshrc"
[[ $PERSONAL_FRAMEWORK_LOADED == 1 ]] || exit 1
''', self.target)

    def test_recovery_from_explicit_backup_preserves_local_and_is_repeatable(self):
        self.recovery_fixture()
        backup = self.state / "backup-20000101T000000Z.directory with spaces"
        backup.mkdir()
        (backup / "zshrc").write_text("alias recovered='present'\nalias preferred='backup'\n")
        existing = "# Current user settings.\nalias preferred='local'\n"
        (self.target / ".zshrc.local").write_text(existing)
        prompt_before = (self.target / ".p10k.zsh").read_bytes()
        result = self.recovery(backup)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.output.write_bytes((self.target / ".zshrc.local").read_bytes())
        self.load_local("[[ $aliases[recovered] == present && $aliases[preferred] == local ]] || exit 1")
        self.assertIn(existing, self.output.read_text())
        self.assertEqual((self.target / ".p10k.zsh").read_bytes(), prompt_before)
        before = self.file_snapshot()
        snapshot = self.root / "recovery-tree.json"
        subprocess.run([sys.executable, str(REPO / "tests/snapshot_tree.py"), "capture", str(self.target), str(snapshot)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        result = self.recovery(backup)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.file_snapshot(), before)
        subprocess.run([sys.executable, str(REPO / "tests/snapshot_tree.py"), "check", str(self.target), str(snapshot)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_recovery_keeps_current_active_customizations_over_older_backup(self):
        self.recovery_fixture()
        backup = self.state / "backup-20000101T000000Z.personal"
        backup.mkdir()
        (backup / "zshrc").write_text("alias preferred='old-backup'\n")
        active = self.target / ".zshrc"
        active.write_text(active.read_text() + "\nalias preferred='current-active'\n")
        result = self.recovery(backup)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.output.write_bytes((self.target / ".zshrc.local").read_bytes())
        self.load_local("[[ $aliases[preferred] == current-active ]] || exit 1")

    def test_recovery_preserves_edits_inside_existing_migrated_settings(self):
        self.recovery_fixture()
        self.helper("alias preferred='initially-migrated'\n")
        edited = self.output.read_text().replace("alias preferred='initially-migrated'", "alias preferred='edited-after-migration'", 1)
        (self.target / ".zshrc.local").write_text(edited)
        backup = self.state / "backup-20000101T000000Z.personal"
        backup.mkdir()
        (backup / "zshrc").write_text("alias preferred='old-backup'\nalias recovered='present'\n")
        result = self.recovery(backup)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.output.write_bytes((self.target / ".zshrc.local").read_bytes())
        self.load_local("[[ $aliases[preferred] == edited-after-migration && $aliases[recovered] == present ]] || exit 1")

    def test_recovery_refuses_to_override_current_early_setting_with_late_backup(self):
        self.recovery_fixture()
        self.helper('alias preferred=current\nsource "$ZSH/oh-my-zsh.sh"\n')
        (self.target / ".zshrc.local").write_bytes(self.output.read_bytes())
        backup = self.state / "backup-20000101T000000Z.personal"
        backup.mkdir()
        (backup / "zshrc").write_text("alias preferred=older\nalias recovered=present\n")
        before = self.file_snapshot()
        result = self.recovery(backup)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.file_snapshot(), before)

    def test_recovery_chooses_latest_personal_zshrc_backup(self):
        self.recovery_fixture()
        for name, content in [
            ("backup-20000101T000000Z.old", "alias recovered='older'\n"),
            ("backup-20000102T000000Z.personal", "alias recovered='latest-personal'\n"),
            ("backup-20000104T000000Z.shared", self.template.read_text()),
        ]:
            directory = self.state / name
            directory.mkdir()
            (directory / "zshrc").write_text(content)
        local_only = self.state / "backup-20000103T000000Z.local-only"
        local_only.mkdir()
        (local_only / "zshrc.local").write_text("alias unrelated='unused'\n")
        result = self.recovery()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.output.write_bytes((self.target / ".zshrc.local").read_bytes())
        self.load_local("[[ $aliases[recovered] == latest-personal ]] || exit 1")

    def test_recovery_without_backup_is_a_safe_failure(self):
        self.recovery_fixture()
        (self.target / ".zshrc.local").write_text("alias preserved='current'\n")
        before = self.file_snapshot()
        result = self.recovery()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.file_snapshot(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
