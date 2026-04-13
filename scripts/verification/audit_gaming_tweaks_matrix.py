#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class EvidenceNeedle:
    path: str
    needle: str


@dataclass(frozen=True)
class Check:
    tier: str
    name: str
    evidence: tuple[EvidenceNeedle, ...]


CHECKS: tuple[Check, ...] = (
    Check('Tier 1', 'Disable Core Isolation / Memory Integrity (HVCI)', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', 'EnableVirtualizationBasedSecurity'),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', 'HypervisorEnforcedCodeIntegrity'),
    )),
    Check('Tier 1', 'Set Win32PrioritySeparation = 26', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'Win32PrioritySeparation' -Value 0x26"),
    )),
    Check('Tier 1', 'Set Games task priority = High', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'Scheduling Category' -Value 'High'"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'Priority' -Value 6"),
    )),
    Check('Tier 1', 'Set SystemResponsiveness = 0–10', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'SystemResponsiveness' -Value 10"),
    )),
    Check('Tier 1', 'Set Multimedia scheduling to favor games', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'Scheduling Category' -Value 'High'"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'GPU Priority' -Value 8"),
    )),
    Check('Tier 1', 'Disable Virtual Machine Platform', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "DisplayName 'Virtual Machine Platform'"),
    )),
    Check('Tier 1', 'Disable Windows Hypervisor Platform', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "DisplayName 'Windows Hypervisor Platform'"),
    )),
    Check('Tier 1', 'Disable Application Guard', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "DisplayName 'Application Guard'"),
    )),
    Check('Tier 1', 'Disable Credential Guard, if present', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'LsaCfgFlags' -Value 0"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "ArgumentList @('/set', 'vsmlaunchtype', 'off')"),
    )),

    Check('Tier 2', 'Disable SysMain (Superfetch)', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'SysMain',"),
    )),
    Check('Tier 2', 'Disable Windows Search indexing', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'WSearch',"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', 'IndexerAutomaticMaintenance'),
    )),
    Check('Tier 2', 'Disable Xbox Game DVR', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'AllowGameDVR' -Value 0"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "Name = 'GameDVR_Enabled'; Value = 0"),
    )),
    Check('Tier 2', 'Disable Xbox Game Monitoring Service', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'xbgm',"),
    )),
    Check('Tier 2', 'Disable Xbox Live Auth Manager', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'XblAuthManager',"),
    )),
    Check('Tier 2', 'Disable Xbox Live Game Save', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'XblGameSave',"),
    )),
    Check('Tier 2', 'Disable Xbox Live Networking Service', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'XboxNetApiSvc'"),
    )),
    Check('Tier 2', 'Disable Windows Error Reporting', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Privacy.ps1', "'WerSvc' -StartType 'Disabled'"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Privacy.ps1', "'DontShowUI' -Value 1"),
    )),
    Check('Tier 2', 'Disable Retail Demo Service', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'RetailDemo',"),
    )),
    Check('Tier 2', 'Disable Downloaded Maps Manager', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'MapsBroker',"),
    )),
    Check('Tier 2', 'Disable SmartScreen background scanning', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Privacy.ps1', "'EnableSmartScreen' -Value 0"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Privacy.ps1', "Name = 'EnableWebContentEvaluation'; Value = 0"),
    )),

    Check('Tier 3', 'Enable Hardware-Accelerated GPU Scheduling (HAGS)', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'HwSchMode' -Value 2"),
    )),
    Check('Tier 3', 'Enable Variable Refresh Rate', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "VRROptimizeEnable"),
    )),
    Check('Tier 3', 'Enable Optimizations for windowed games', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "SwapEffectUpgradeEnable"),
    )),
    Check('Tier 3', 'Disable Fullscreen Optimizations (per game)', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "GameDVR_DXGIHonorFSEWindowsCompatible"),
    )),
    Check('Tier 3', 'Disable Game DVR FSE capture', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "GameDVR_FSEBehaviorMode"),
    )),
    Check('Tier 3', 'Disable background recording', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "AppCaptureEnabled"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "HistoricalCaptureEnabled"),
    )),
    Check('Tier 3', 'Disable Xbox Game Bar overlay', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "UseNexusForGameBarEnabled"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "ShowStartupPanel"),
    )),
    Check('Tier 3', 'Disable Windows HDR auto switching', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "AutoHDREnable"),
    )),
    Check('Tier 3', 'Disable GPU Timeout Detection (TDR tweaks)', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'TdrLevel' -Value 0"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'TdrDelay' -Value 10"),
    )),
    Check('Tier 3', 'Disable Flip model downgrade registry flags', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "SwapEffectUpgradeEnable"),
    )),

    Check('Tier 4', 'Disable Delivery Optimization P2P', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Privacy.ps1', "'DODownloadMode' -Value 0"),
    )),

    Check('Tier 5', 'Disable Prefetch', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'EnablePrefetcher' -Value 0"),
    )),
    Check('Tier 5', 'Disable Superfetch', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'EnableSuperfetch' -Value 0"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'SysMain',"),
    )),
    Check('Tier 5', 'Disable Memory compression', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', 'Disable-MMAgent -MemoryCompression'),
    )),
    Check('Tier 5', 'Disable Page combining', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', 'Disable-MMAgent -PageCombining'),
    )),
    Check('Tier 5', 'Disable Automatic RAM compression', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', 'Disable-MMAgent -MemoryCompression'),
    )),
    Check('Tier 5', 'Disable hibernate (powercfg -h off)', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Features.ps1', "ArgumentList @('/h', 'off')"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "ArgumentList @('/hibernate', 'off')"),
    )),
    Check('Tier 5', 'Disable fast startup', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'HiberbootEnabled' -Value 0"),
    )),
    Check('Tier 5', 'Disable Storage Sense', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'AllowStorageSenseGlobal' -Value 0"),
    )),

    Check('Tier 6', 'Disable clipboard sync', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Privacy.ps1', "'AllowCrossDeviceClipboard' -Value 0"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Privacy.ps1', "Name = 'EnableCloudClipboard'; Value = 0"),
    )),
    Check('Tier 6', 'Disable Teams auto start', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Features.ps1', "Remove-RegistryValueIfPresent -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'Teams'"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Features.ps1', "Disable-ScheduledTaskIfPresent -TaskPath '\\Microsoft\\Teams\\'"),
    )),
    Check('Tier 6', 'Disable background apps globally', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Features.ps1', "'GlobalUserDisabled' -Value 1"),
    )),
    Check('Tier 6', 'Disable Cortana', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/UI.ps1', "'AllowCortana' -Value 0"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/UI.ps1', "'CortanaConsent'"),
    )),

    Check('Tier 7', 'Disable transparency effects', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'EnableTransparency'"),
    )),
    Check('Tier 7', 'Disable animations', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'MinAnimate' -Value '0'"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "Name = 'VisualFXSetting'; Value = 2"),
    )),
    Check('Tier 7', 'Disable visual effects', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "Name = 'VisualFXSetting'; Value = 2"),
    )),
    Check('Tier 7', 'Disable taskbar animations', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'TaskbarAnimations'"),
    )),
    Check('Tier 7', 'Disable snap animations', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'EnableSnapAssistFlyout'"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'WindowArrangementActive' -Value '0'"),
    )),
    Check('Tier 7', 'Disable desktop wallpaper slideshow', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "Name = 'BackgroundType'; Value = 0"),
    )),
    Check('Tier 7', 'Disable accent color transparency', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'EnableTransparency'"),
    )),
    Check('Tier 7', 'Disable live thumbnails', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "Name = 'DisablePreviewDesktop'; Value = 1"),
    )),
    Check('Tier 7', 'Disable window shadows', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "Name = 'VisualFXSetting'; Value = 2"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "Name = 'ListviewShadow'; Value = 0"),
    )),
    Check('Tier 7', 'Disable smooth scrolling', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'SmoothScroll' -Value '0'"),
    )),

    Check('Tier 8', 'Disable USB selective suspend', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', 'SelectiveSuspendEnabled'),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', 'SelectiveSuspendOn'),
    )),
    Check('Tier 8', 'Disable mouse acceleration', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'MouseSpeed' -Value '0'"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'MouseThreshold1' -Value '0'"),
    )),
    Check('Tier 8', 'Disable keyboard repeat filtering', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "Control Panel\\Accessibility\\Keyboard Response' -Name 'Flags' -Value '0'"),
    )),
    Check('Tier 8', 'Disable touch input services', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'TabletInputService'"),
    )),
    Check('Tier 8', 'Disable HPET (if using TSC timers)', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "ArgumentList @('/deletevalue', 'useplatformclock')"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "ArgumentList @('/deletevalue', 'tscsyncpolicy')"),
    )),
    Check('Tier 8', 'Disable dynamic ticks', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "ArgumentList @('/set', 'disabledynamictick', 'yes')"),
    )),
    Check('Tier 8', 'Disable idle states for USB', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', 'IdleInWorkingState'),
    )),
    Check('Tier 8', 'Disable power saving for PCIe', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "foreach ($bus in @('USB', 'HID', 'PCI'))"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', '"PnPCapabilities"=dword:00000018'),
    )),
    Check('Tier 8', 'Disable Intel Speed Shift EPP', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "Setting = 'PERFEPP'"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "Setting = 'PERFEPP1'"),
    )),

    Check('Tier 9', 'Disable Windows Defender real-time scanning for game folders', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', 'function Get-HunterDetectedGameLibraryPaths'),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', 'Add-MpPreference -ExclusionPath $pathsToAdd'),
    )),
    Check('Tier 9', 'Disable scheduled maintenance', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'MaintenanceDisabled' -Value 1"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "Disable-ScheduledTaskIfPresent -TaskPath '\\Microsoft\\Windows\\TaskScheduler\\' -TaskName 'Regular Maintenance'"),
    )),
    Check('Tier 9', 'Disable automatic defrag schedule', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "Disable-ScheduledTaskIfPresent -TaskPath '\\Microsoft\\Windows\\Defrag\\' -TaskName 'ScheduledDefrag'"),
    )),
    Check('Tier 9', 'Disable error reporting popups', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Privacy.ps1', "'DontShowUI' -Value 1"),
    )),
    Check('Tier 9', 'Disable diagnostic feedback', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Privacy.ps1', "'DoNotShowFeedbackNotifications' -Value 1"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Privacy.ps1', "'NumberOfSIUFInPeriod' -Value 0"),
    )),
    Check('Tier 9', 'Disable location services', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Privacy.ps1', "'SensorPermissionState' -Value 0"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Privacy.ps1', "'Status' -Value 0"),
    )),
    Check('Tier 9', 'Disable Bluetooth if unused', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'bthserv',"),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'BTAGService',"),
    )),
    Check('Tier 9', 'Disable Wi-Fi scanning service', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', 'function Test-ShouldDisableWlanService'),
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "$disabledServices += 'WlanSvc'"),
    )),
    Check('Tier 9', 'Disable Windows Ink', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Specialized.ps1', "'AllowWindowsInkWorkspace' -Value 0"),
    )),
    Check('Tier 9', 'Disable tablet mode services', (
        EvidenceNeedle('src/Hunter/Private/Tasks/Tweaks/Hardware.ps1', "'TabletInputService'"),
    )),
)


def find_line_number(text: str, needle: str) -> int | None:
    for index, line in enumerate(text.splitlines(), start=1):
        if needle in line:
            return index
    return None


def main() -> int:
    cache: dict[Path, str] = {}
    failures: list[str] = []

    for check in CHECKS:
        references: list[str] = []
        for evidence in check.evidence:
            path = REPO_ROOT / evidence.path
            text = cache.setdefault(path, path.read_text(encoding='utf-8'))
            line_number = find_line_number(text, evidence.needle)
            if line_number is None:
                failures.append(f"[{check.tier}] {check.name}: missing evidence '{evidence.needle}' in {evidence.path}")
            else:
                references.append(f"{evidence.path}:{line_number}")

        if not failures or not failures[-1].startswith(f'[{check.tier}] {check.name}:'):
            print(f"PASS | {check.tier} | {check.name} | {', '.join(references)}")

    if failures:
        print('\nAudit failed:', file=sys.stderr)
        for failure in failures:
            print(f" - {failure}", file=sys.stderr)
        return 1

    print(f"\nAudit passed: {len(CHECKS)} matrix checks matched source evidence.")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
