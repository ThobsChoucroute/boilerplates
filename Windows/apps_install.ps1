# ==========================================================
#  Script d'installation groupée d'applications via winget
#  Lancez-le depuis n'importe quel PowerShell (non admin) :
#  Lancer avec: Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; .\apps_install.ps1
# ==========================================================

# Verifie que winget est disponible
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "winget n'est pas installe ou introuvable. Installez 'App Installer' depuis le Microsoft Store." -ForegroundColor Red
    exit 1
}

# --- Auto-elevation -----------------------------------------
# Si le script est lance sans droits admin, on se relance eleve (prompt UAC).
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $elevated) {
    Write-Host "Ce script requiert les droits administrateur. Elevation en cours..." -ForegroundColor Yellow
    try {
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -Wait
    } catch {
        Write-Host "Elevation refusee. Relancez en tant qu'administrateur." -ForegroundColor Red
        exit 1
    }
    exit 0
}

# --- Liste des applications a installer -------------------
# Remplacez / ajoutez / supprimez selon vos besoins.
# Le format est : "Id.winget" ; pour trouver l'ID exact d'une appli :
#   winget search "nom de l'appli"
$apps = @(
    # Navigateur
    @{ Id = "ImputNet.Helium"}               # Helium

    # Jeux
    @{ Id = "Valve.Steam"}                  # Steam
    @{ Id = "EpicGames.EpicGamesLauncher"}   # Epic Games
    @{ Id = "Blizzard.BattleNet"; ExtraArgs = @("--location", "C:\Program Files (x86)\Battle.net") }  # Battle.net

    # Utilitaires 
    @{ Id = "Discord.Discord"}              # Discord
    @{ Id = "Spotify.Spotify"; Elevation = "Prohibited"}  # Spotify (refuse d'etre installe en admin)
    @{ Id = "Proton.ProtonVPN"}             # Proton VPN
    @{ Id = "Skillbrains.Lightshot"}        # Lightshot
    @{ Id = "AmN.yasb"}                     # YASB (Yet Another Status Bar)
    @{ Id = "NZXT.CAM"}                     # NZXT CAM
    @{ Id = "flux.flux"}                    # f.lux
    @{ Id = "Flow-Launcher.Flow-Launcher"}  # Flow Launcher
    @{ Id = "Logitech.GHUB"}                # Logitech G HUB
    @{ Id = "GIGABYTE.RGBFusion"}            # RGB Fusion (Gigabyte)

    # Dev
    @{ Id = "Microsoft.VisualStudioCode"}   # Visual Studio Code
    @{ Id = "beekeeper-studio.beekeeper-studio"}  # Beekeeper Studio
)

# --- Installation -------------------------------------------
# Lance une commande winget en contexte non-eleve (packages "ElevationProhibited"
# comme Spotify, dont l'installeur refuse toute session administrateur).
function Invoke-WingetAsUser {
    param([string[]]$Arguments)

    # Chemin absolu de winget : le Task Scheduler ne connait pas WindowsApps dans son PATH
    $wingetExe = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
    if (-not $wingetExe) {
        $wingetExe = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
    }
    if (-not (Test-Path $wingetExe)) {
        throw "winget.exe introuvable (chemin : $wingetExe)."
    }

    $taskPath = "\WingetInstall\"
    $taskName = "WingetDeElevated_$([Guid]::NewGuid().ToString('N'))"
    $principal = New-ScheduledTaskPrincipal -UserId (whoami) -LogonType Interactive -RunLevel Limited
    $action    = New-ScheduledTaskAction -Execute $wingetExe -Argument ($Arguments -join ' ')
    try {
        Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath

        # Attend la fin de la tache (267009 = 0x41301 : pas encore executee)
        $deadline = (Get-Date).AddMinutes(10)
        do {
            Start-Sleep -Milliseconds 500
            $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath
            $ran  = $info.LastRunTime -ne [datetime]::MinValue -and $info.LastTaskResult -ne 267009
        } while (-not $ran -and (Get-Date) -lt $deadline)

        if ($ran) {
            return $info.LastTaskResult
        } else {
            return -1
        }
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
    }
}

Write-Host "Debut de l'installation de $($apps.Count) application(s)...`n" -ForegroundColor Cyan
 
foreach ($app in $apps) {
    Write-Host "Installation de : $($app.Id)" -ForegroundColor Yellow
    $installArgs = @("install", "--id", $app.Id, "--exact", "--silent", "--source", "winget", "--accept-package-agreements", "--accept-source-agreements")
    if ($app.ExtraArgs) {
        $installArgs += $app.ExtraArgs
    }

    if ($elevated -and $app.Elevation -eq "Prohibited") {
        $exitCode = Invoke-WingetAsUser -Arguments $installArgs
    } else {
        winget @installArgs
        $exitCode = $LASTEXITCODE
    }
 
    if ($exitCode -eq 0) {
        Write-Host "-> $($app.Id) installe avec succes.`n" -ForegroundColor Green
    } else {
        Write-Host "-> Erreur lors de l'installation de $($app.Id) (code $exitCode).`n" -ForegroundColor Red
    }
}

Write-Host "Installation terminee !" -ForegroundColor Cyan

# ==========================================================
#  Installation de Taskbar Hide (thide) - pas de paquet winget
#  Telechargement automatique du dernier .msi depuis GitHub
# ==========================================================

Write-Host "`nInstallation de Taskbar Hide (thide)..." -ForegroundColor Yellow

try {
    # Determine l'architecture (x64 ou arm64)
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }

    # Recupere les infos de la derniere release via l'API GitHub
    $releaseUrl = "https://api.github.com/repos/amnweb/thide/releases/latest"
    $release = Invoke-RestMethod -Uri $releaseUrl -Headers @{ "User-Agent" = "PowerShell" }

    # Cherche l'asset .msi correspondant a l'architecture
    $asset = $release.assets | Where-Object { $_.name -like "*$arch.msi" } | Select-Object -First 1

    if (-not $asset) {
        throw "Aucun installeur .msi trouve pour l'architecture $arch."
    }

    $msiUrl  = $asset.browser_download_url
    $msiPath = Join-Path $env:TEMP $asset.name

    Write-Host "Telechargement : $($asset.name)" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing

    Write-Host "Installation silencieuse en cours..." -ForegroundColor Cyan
    $process = Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait -PassThru

    if ($process.ExitCode -eq 0) {
        Write-Host "-> Taskbar Hide installe avec succes.`n" -ForegroundColor Green
    } else {
        Write-Host "-> Erreur lors de l'installation de Taskbar Hide (code $($process.ExitCode)).`n" -ForegroundColor Red
    }

    # Nettoyage du fichier telecharge
    Remove-Item $msiPath -ErrorAction SilentlyContinue
}
catch {
    Write-Host "-> Echec de l'installation de Taskbar Hide : $($_.Exception.Message)`n" -ForegroundColor Red
}
