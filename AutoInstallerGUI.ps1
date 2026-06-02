param(
    [string]$InitialFolder = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-Arg {
    param([string]$Value)
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Format-FileSizeMb {
    param([long]$Bytes)
    return ("{0:N1}" -f ($Bytes / 1MB))
}

function Get-InstallerType {
    param([string]$Path)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        ".msi" { return "MSI" }
        ".msu" { return "MSU" }
        ".exe" { return "EXE" }
        default { return $ext.TrimStart(".").ToUpperInvariant() }
    }
}

function Get-MsiProperty {
    param([string]$Path, [string]$PropertyName)

    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $null, $installer, @($Path, 0))
        $query = "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='{0}'" -f ($PropertyName -replace "'", "''")
        $view = $database.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $database, @($query))
        $view.GetType().InvokeMember("Execute", "InvokeMethod", $null, $view, $null) | Out-Null
        $record = $view.GetType().InvokeMember("Fetch", "InvokeMethod", $null, $view, $null)
        if ($record) {
            return $record.GetType().InvokeMember("StringData", "GetProperty", $null, $record, 1)
        }
    } catch {
        return ""
    }

    return ""
}

function Remove-VersionText {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    $clean = $Name -replace "[_\.]+", " "
    $clean = $clean -replace "(?i)\b(setup|installer|install|x64|x86|win64|win32|windows|offline|online)\b", " "
    $clean = $clean -replace "(?i)(^|[\s\-_])v?\d+(\.\d+){1,4}([a-z0-9\-_\.]*)?", " "
    $clean = $clean -replace "\s{2,}", " "
    $clean = $clean.Trim(" -_")
    if ([string]::IsNullOrWhiteSpace($clean)) { return $Name.Trim() }
    return $clean
}

function Get-InstallerDisplayName {
    param([string]$Path)

    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $name = ""

    if ($ext -eq ".msi") {
        $name = Get-MsiProperty -Path $Path -PropertyName "ProductName"
    } elseif ($ext -eq ".exe") {
        try {
            $vi = (Get-Item -LiteralPath $Path).VersionInfo
            foreach ($candidate in @($vi.ProductName, $vi.FileDescription)) {
                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    $name = $candidate
                    break
                }
            }
        } catch {
            $name = ""
        }
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    }

    return (Remove-VersionText -Name $name)
}

function Get-ExeSilentCandidates {
    param([string]$Path, [bool]$TryCommonSwitches)

    $metadata = ""
    try {
        $vi = (Get-Item -LiteralPath $Path).VersionInfo
        $metadata = @(
            $vi.CompanyName
            $vi.ProductName
            $vi.FileDescription
            $vi.OriginalFilename
            $vi.InternalName
        ) -join " "
    } catch {
        $metadata = ""
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($metadata -match "Inno Setup") {
        [void]$candidates.Add("/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-")
    }
    if ($metadata -match "Nullsoft|NSIS") {
        [void]$candidates.Add("/S")
    }
    if ($metadata -match "InstallShield") {
        [void]$candidates.Add('/s /v"/qn /norestart"')
    }
    if ($metadata -match "WiX|Burn Bootstrapper") {
        [void]$candidates.Add("/quiet /norestart")
    }
    if ($metadata -match "Squirrel") {
        [void]$candidates.Add("--silent")
    }
    if ($metadata -match "Advanced Installer") {
        [void]$candidates.Add("/exenoui /qn /norestart")
    }

    if ($TryCommonSwitches) {
        foreach ($arg in @(
            "/S",
            "/silent",
            "/verysilent /suppressmsgboxes /norestart /sp-",
            "/quiet /norestart",
            "/passive /norestart",
            "--silent",
            "--quiet"
        )) {
            if (-not $candidates.Contains($arg)) {
                [void]$candidates.Add($arg)
            }
        }
    }

    return @($candidates.ToArray())
}

function Invoke-Installer {
    param(
        [string]$Path,
        [string]$Type,
        [bool]$TryCommonSwitches,
        [bool]$InteractiveFallback,
        [scriptblock]$Log
    )

    & $Log ("Starting: {0}" -f $Path)

    if ($Type -eq "MSI") {
        $args = "/i " + (Quote-Arg $Path) + " /qn /norestart"
        & $Log ("Command: msiexec.exe {0}" -f $args)
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru
        return $process.ExitCode
    }

    if ($Type -eq "MSU") {
        $args = (Quote-Arg $Path) + " /quiet /norestart"
        & $Log ("Command: wusa.exe {0}" -f $args)
        $process = Start-Process -FilePath "wusa.exe" -ArgumentList $args -Wait -PassThru
        return $process.ExitCode
    }

    if ($Type -eq "EXE") {
        $attempts = Get-ExeSilentCandidates -Path $Path -TryCommonSwitches:$TryCommonSwitches
        if ($attempts.Count -eq 0) {
            if ($InteractiveFallback) {
                & $Log "No silent switch detected. Opening normal installer window."
                $process = Start-Process -FilePath $Path -Wait -PassThru
                return $process.ExitCode
            }
            & $Log "No silent switch detected. Skipped."
            return 9991
        }

        foreach ($args in $attempts) {
            & $Log ("Trying EXE arguments: {0}" -f $args)
            try {
                $process = Start-Process -FilePath $Path -ArgumentList $args -Wait -PassThru
                if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
                    return $process.ExitCode
                }
                & $Log ("Exit code {0}; trying next option if available." -f $process.ExitCode)
            } catch {
                & $Log ("Failed to start with these arguments: {0}" -f $_.Exception.Message)
            }
        }

        if ($InteractiveFallback) {
            & $Log "Silent attempts did not report success. Opening normal installer window."
            $process = Start-Process -FilePath $Path -Wait -PassThru
            return $process.ExitCode
        }

        return 9992
    }

    & $Log "Unsupported installer type."
    return 9990
}

function Move-FailedInstaller {
    param(
        [string]$Path,
        [string]$FailFolder,
        [scriptblock]$Log
    )

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            & $Log ("Cannot move failed installer because the file was not found: {0}" -f $Path)
            return $false
        }

        New-Item -ItemType Directory -Path $FailFolder -Force | Out-Null

        $source = [IO.FileInfo](Get-Item -LiteralPath $Path)
        $failDir = [IO.DirectoryInfo](Get-Item -LiteralPath $FailFolder)
        if ($source.Directory.FullName.TrimEnd("\") -ieq $failDir.FullName.TrimEnd("\")) {
            & $Log ("Failed installer is already in Fail folder: {0}" -f $source.Name)
            return $true
        }

        $target = Join-Path $FailFolder $source.Name
        if (Test-Path -LiteralPath $target) {
            $baseName = [IO.Path]::GetFileNameWithoutExtension($source.Name)
            $extension = [IO.Path]::GetExtension($source.Name)
            $counter = 1
            do {
                $target = Join-Path $FailFolder ("{0} ({1}){2}" -f $baseName, $counter, $extension)
                $counter++
            } while (Test-Path -LiteralPath $target)
        }

        Move-Item -LiteralPath $Path -Destination $target
        & $Log ("Moved failed installer to Fail folder: {0}" -f $target)
        return $true
    } catch {
        & $Log ("Could not move failed installer to Fail folder: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Set-AeroButton {
    param(
        [System.Windows.Forms.Button]$Button,
        [bool]$Primary = $false
    )

    $Button.FlatStyle = "Flat"
    $Button.UseVisualStyleBackColor = $false
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand

    if ($Primary) {
        $normal = [Drawing.Color]::FromArgb(32, 126, 206)
        $hover = [Drawing.Color]::FromArgb(67, 158, 231)
        $down = [Drawing.Color]::FromArgb(20, 92, 160)
        $border = [Drawing.Color]::FromArgb(13, 86, 150)
        $Button.BackColor = $normal
        $Button.ForeColor = [Drawing.Color]::White
        $Button.Font = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    } else {
        $normal = [Drawing.Color]::FromArgb(232, 244, 252)
        $hover = [Drawing.Color]::FromArgb(210, 234, 250)
        $down = [Drawing.Color]::FromArgb(184, 216, 238)
        $border = [Drawing.Color]::FromArgb(122, 170, 205)
        $Button.BackColor = $normal
        $Button.ForeColor = [Drawing.Color]::FromArgb(28, 56, 74)
        $Button.Font = New-Object Drawing.Font("Segoe UI", 9)
    }

    $Button.FlatAppearance.BorderColor = $border
    $Button.FlatAppearance.BorderSize = 1
    $Button.FlatAppearance.MouseOverBackColor = $hover
    $Button.FlatAppearance.MouseDownBackColor = $down
    $Button.Tag = [pscustomobject]@{
        Normal = $normal
        IsPrimary = $Primary
    }
    $Button.Add_MouseLeave({ $this.BackColor = $this.Tag.Normal })
    $Button.Add_EnabledChanged({
        if ($this.Enabled) {
            $this.BackColor = $this.Tag.Normal
            $this.ForeColor = if ($this.Tag.IsPrimary) { [Drawing.Color]::White } else { [Drawing.Color]::FromArgb(28, 56, 74) }
        } else {
            $this.BackColor = [Drawing.Color]::FromArgb(222, 229, 234)
            $this.ForeColor = [Drawing.Color]::FromArgb(120, 132, 140)
        }
    })
}

function New-Form {
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Folder Auto Installer - Windows 10"
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object Drawing.Size(900, 650)
    $form.MinimumSize = New-Object Drawing.Size(820, 560)
    $form.BackColor = [Drawing.Color]::FromArgb(224, 241, 252)

    $font = New-Object Drawing.Font("Segoe UI", 9)
    $form.Font = $font

    $topPanel = New-Object System.Windows.Forms.Panel
    $topPanel.Dock = "Top"
    $topPanel.Height = 122
    $topPanel.Padding = New-Object Windows.Forms.Padding(12, 12, 12, 6)
    $topPanel.BackColor = [Drawing.Color]::FromArgb(221, 240, 252)
    $topPanel.Add_Paint({
        param($sender, $eventArgs)
        $rect = $sender.ClientRectangle
        if ($rect.Width -le 0 -or $rect.Height -le 0) { return }
        $brush = New-Object Drawing.Drawing2D.LinearGradientBrush(
            $rect,
            [Drawing.Color]::FromArgb(248, 252, 255),
            [Drawing.Color]::FromArgb(203, 229, 247),
            90
        )
        $eventArgs.Graphics.FillRectangle($brush, $rect)
        $brush.Dispose()
        $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(143, 190, 224))
        $eventArgs.Graphics.DrawLine($pen, 0, $rect.Height - 1, $rect.Width, $rect.Height - 1)
        $pen.Dispose()
    }.GetNewClosure())
    $form.Controls.Add($topPanel)

    $folderLabel = New-Object System.Windows.Forms.Label
    $folderLabel.Text = "Installer folder:"
    $folderLabel.AutoSize = $true
    $folderLabel.Location = New-Object Drawing.Point(12, 16)
    $folderLabel.BackColor = [Drawing.Color]::Transparent
    $folderLabel.ForeColor = [Drawing.Color]::FromArgb(38, 70, 92)
    $topPanel.Controls.Add($folderLabel)

    $folderText = New-Object System.Windows.Forms.TextBox
    $folderText.Anchor = "Top,Left,Right"
    $folderText.Location = New-Object Drawing.Point(112, 12)
    $folderText.Size = New-Object Drawing.Size(520, 24)
    $folderText.Text = $InitialFolder
    $folderText.ReadOnly = $true
    $folderText.BackColor = [Drawing.Color]::FromArgb(250, 253, 255)
    $folderText.ForeColor = [Drawing.Color]::FromArgb(24, 45, 60)
    $topPanel.Controls.Add($folderText)

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Anchor = "Top,Right"
    $browseButton.Text = "Select folder..."
    $browseButton.Location = New-Object Drawing.Point(646, 10)
    $browseButton.Size = New-Object Drawing.Size(112, 28)
    Set-AeroButton -Button $browseButton
    $topPanel.Controls.Add($browseButton)

    $tempButton = New-Object System.Windows.Forms.Button
    $tempButton.Anchor = "Top,Right"
    $tempButton.Text = "New temp"
    $tempButton.Location = New-Object Drawing.Point(768, 10)
    $tempButton.Size = New-Object Drawing.Size(78, 28)
    Set-AeroButton -Button $tempButton
    $topPanel.Controls.Add($tempButton)

    $scanButton = New-Object System.Windows.Forms.Button
    $scanButton.Text = "Scan"
    $scanButton.Location = New-Object Drawing.Point(112, 50)
    $scanButton.Size = New-Object Drawing.Size(92, 28)
    Set-AeroButton -Button $scanButton
    $topPanel.Controls.Add($scanButton)

    $installButton = New-Object System.Windows.Forms.Button
    $installButton.Text = "Start installing"
    $installButton.Location = New-Object Drawing.Point(214, 44)
    $installButton.Size = New-Object Drawing.Size(158, 40)
    Set-AeroButton -Button $installButton -Primary $true
    $topPanel.Controls.Add($installButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Location = New-Object Drawing.Point(384, 50)
    $cancelButton.Size = New-Object Drawing.Size(92, 28)
    $cancelButton.Enabled = $false
    Set-AeroButton -Button $cancelButton
    $topPanel.Controls.Add($cancelButton)

    $openButton = New-Object System.Windows.Forms.Button
    $openButton.Text = "Open folder"
    $openButton.Location = New-Object Drawing.Point(486, 50)
    $openButton.Size = New-Object Drawing.Size(104, 28)
    Set-AeroButton -Button $openButton
    $topPanel.Controls.Add($openButton)

    $adminButton = New-Object System.Windows.Forms.Button
    $adminButton.Anchor = "Top,Right"
    $adminButton.Text = "Restart as admin"
    $adminButton.Location = New-Object Drawing.Point(704, 48)
    $adminButton.Size = New-Object Drawing.Size(142, 28)
    Set-AeroButton -Button $adminButton
    $topPanel.Controls.Add($adminButton)

    $recursiveCheck = New-Object System.Windows.Forms.CheckBox
    $recursiveCheck.Text = "Include subfolders"
    $recursiveCheck.Location = New-Object Drawing.Point(112, 92)
    $recursiveCheck.Size = New-Object Drawing.Size(140, 24)
    $recursiveCheck.BackColor = [Drawing.Color]::Transparent
    $recursiveCheck.ForeColor = [Drawing.Color]::FromArgb(38, 70, 92)
    $topPanel.Controls.Add($recursiveCheck)

    $commonSwitchCheck = New-Object System.Windows.Forms.CheckBox
    $commonSwitchCheck.Text = "Try common silent switches for EXE"
    $commonSwitchCheck.Checked = $true
    $commonSwitchCheck.Location = New-Object Drawing.Point(260, 92)
    $commonSwitchCheck.Size = New-Object Drawing.Size(230, 24)
    $commonSwitchCheck.BackColor = [Drawing.Color]::Transparent
    $commonSwitchCheck.ForeColor = [Drawing.Color]::FromArgb(38, 70, 92)
    $topPanel.Controls.Add($commonSwitchCheck)

    $fallbackCheck = New-Object System.Windows.Forms.CheckBox
    $fallbackCheck.Text = "Fallback to normal installer window"
    $fallbackCheck.Location = New-Object Drawing.Point(500, 92)
    $fallbackCheck.Size = New-Object Drawing.Size(230, 24)
    $fallbackCheck.BackColor = [Drawing.Color]::Transparent
    $fallbackCheck.ForeColor = [Drawing.Color]::FromArgb(38, 70, 92)
    $topPanel.Controls.Add($fallbackCheck)

    $status = New-Object System.Windows.Forms.StatusStrip
    $status.Dock = "Bottom"
    $status.BackColor = [Drawing.Color]::FromArgb(211, 234, 249)
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.ForeColor = [Drawing.Color]::FromArgb(38, 70, 92)
    [void]$status.Items.Add($statusLabel)
    $form.Controls.Add($status)

    $contentPanel = New-Object System.Windows.Forms.Panel
    $contentPanel.Dock = "None"
    $contentPanel.Padding = New-Object Windows.Forms.Padding(0, 0, 0, 0)
    $contentPanel.BackColor = [Drawing.Color]::FromArgb(247, 252, 255)
    $form.Controls.Add($contentPanel)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Dock = "Fill"
    $logBox.Multiline = $true
    $logBox.ScrollBars = "Vertical"
    $logBox.ReadOnly = $true
    $logBox.Font = New-Object Drawing.Font("Consolas", 9)
    $logBox.BorderStyle = "FixedSingle"
    $logBox.BackColor = [Drawing.Color]::FromArgb(247, 252, 255)
    $logBox.ForeColor = [Drawing.Color]::FromArgb(23, 57, 76)
    $contentPanel.Controls.Add($logBox)

    $script:AI_Form = $form
    $script:AI_TopPanel = $topPanel
    $script:AI_ContentPanel = $contentPanel
    $script:AI_StatusBar = $status
    $script:AI_FolderText = $folderText
    $script:AI_BrowseButton = $browseButton
    $script:AI_TempButton = $tempButton
    $script:AI_ScanButton = $scanButton
    $script:AI_InstallButton = $installButton
    $script:AI_CancelButton = $cancelButton
    $script:AI_OpenButton = $openButton
    $script:AI_AdminButton = $adminButton
    $script:AI_RecursiveCheck = $recursiveCheck
    $script:AI_CommonSwitchCheck = $commonSwitchCheck
    $script:AI_FallbackCheck = $fallbackCheck
    $script:AI_CancelRequested = $false
    $script:AI_LogBox = $logBox
    $script:AI_StatusLabel = $statusLabel
    $script:Installers = @()
    $script:LogFile = $null

    function script:Update-LogLayout {
        $topHeight = $script:AI_TopPanel.Height
        $statusHeight = $script:AI_StatusBar.Height
        $height = $script:AI_Form.ClientSize.Height - $topHeight - $statusHeight
        if ($height -lt 80) { $height = 80 }

        $script:AI_ContentPanel.Location = New-Object Drawing.Point(0, $topHeight)
        $script:AI_ContentPanel.Size = New-Object Drawing.Size($script:AI_Form.ClientSize.Width, $height)
        $script:AI_ContentPanel.Anchor = "Top,Bottom,Left,Right"
        $script:AI_ContentPanel.BringToFront()
        $script:AI_TopPanel.BringToFront()
        $script:AI_StatusBar.BringToFront()
    }

    $form.Add_Resize({ Update-LogLayout })
    Update-LogLayout

    function script:Add-Log {
        param([string]$Message)
        if ([string]::IsNullOrEmpty($Message)) {
            $script:AI_LogBox.AppendText([Environment]::NewLine)
            $script:AI_LogBox.SelectionStart = $script:AI_LogBox.TextLength
            $script:AI_LogBox.ScrollToCaret()
            if ($script:LogFile) {
                Add-Content -LiteralPath $script:LogFile -Value "" -Encoding UTF8
            }
            [System.Windows.Forms.Application]::DoEvents()
            return
        }
        $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
        $script:AI_LogBox.AppendText($line + [Environment]::NewLine)
        $script:AI_LogBox.SelectionStart = $script:AI_LogBox.TextLength
        $script:AI_LogBox.ScrollToCaret()
        if ($script:LogFile) {
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
        }
        [System.Windows.Forms.Application]::DoEvents()
    }

    function script:Update-AdminState {
        if (Test-IsAdministrator) {
            $script:AI_StatusLabel.Text = "Running as administrator."
            $script:AI_AdminButton.Enabled = $false
            $script:AI_InstallButton.Enabled = $true
        } else {
            $script:AI_StatusLabel.Text = "Not running as administrator. Restart as admin before installing."
            $script:AI_AdminButton.Enabled = $true
            $script:AI_InstallButton.Enabled = $false
        }
    }

    function script:Scan-Folder {
        $folder = $script:AI_FolderText.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($folder) -or -not (Test-Path -LiteralPath $folder -PathType Container)) {
            [System.Windows.Forms.MessageBox]::Show("Please choose an existing folder.", "Folder Auto Installer") | Out-Null
            return
        }

        $script:Installers = @()
        $search = if ($script:AI_RecursiveCheck.Checked) { "AllDirectories" } else { "TopDirectoryOnly" }
        $files = @(Get-ChildItem -LiteralPath $folder -File -Recurse:($search -eq "AllDirectories") |
            Where-Object { $_.Extension -match "^\.(msi|exe|msu)$" } |
            Sort-Object Name)

        foreach ($file in $files) {
            $type = Get-InstallerType -Path $file.FullName
            $displayName = Get-InstallerDisplayName -Path $file.FullName
            $entry = [pscustomobject]@{
                Path = $file.FullName
                Name = $displayName
                FileName = $file.Name
                Type = $type
                SizeMb = (Format-FileSizeMb -Bytes $file.Length)
                Status = "Ready"
            }
            $script:Installers += $entry
        }

        $script:LogFile = Join-Path $folder ("InstRec-{0}.txt" -f (Get-Date -Format "MMdd"))
        $exeCount = @($script:Installers | Where-Object { $_.Type -eq "EXE" }).Count
        $msiCount = @($script:Installers | Where-Object { $_.Type -eq "MSI" }).Count
        $msuCount = @($script:Installers | Where-Object { $_.Type -eq "MSU" }).Count
        Add-Log ("Scan folder: {0}" -f $folder)
        Add-Log ("Scan complete: {0} installer(s). EXE: {1}, MSI: {2}, MSU: {3}" -f $script:Installers.Count, $exeCount, $msiCount, $msuCount)
    }

    $browseButton.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Select the folder that contains installer files"
        $dlg.ShowNewFolderButton = $true
        $currentFolder = $script:AI_FolderText.Text.Trim()
        if ($currentFolder.Length -gt 0 -and (Test-Path -LiteralPath $currentFolder -PathType Container)) {
            $dlg.SelectedPath = $currentFolder
        }
        if ($dlg.ShowDialog() -eq "OK") {
            $script:AI_FolderText.Text = $dlg.SelectedPath
            $script:LogFile = $null
            Add-Log ("Selected folder: {0}" -f $dlg.SelectedPath)
            Scan-Folder
        }
    })

    $tempButton.Add_Click({
        $folder = Join-Path ([IO.Path]::GetTempPath()) ("AutoInstallerQueue-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $script:AI_FolderText.Text = $folder
        Start-Process explorer.exe -ArgumentList (Quote-Arg $folder)
        $script:LogFile = $null
        Scan-Folder
        Add-Log "Temporary folder created. Put installer files there, then click Scan."
    })

    $openButton.Add_Click({
        $folder = $script:AI_FolderText.Text.Trim()
        if ($folder.Length -gt 0 -and (Test-Path -LiteralPath $folder -PathType Container)) {
            Start-Process explorer.exe -ArgumentList (Quote-Arg $folder)
        }
    })

    $scanButton.Add_Click({ Scan-Folder })

    $adminButton.Add_Click({
        $args = "-NoProfile -ExecutionPolicy Bypass -STA -File " + (Quote-Arg $PSCommandPath)
        if ($script:AI_FolderText.Text.Trim().Length -gt 0) {
            $args += " -InitialFolder " + (Quote-Arg $script:AI_FolderText.Text.Trim())
        }
        Start-Process -FilePath "powershell.exe" -ArgumentList $args -Verb RunAs
        $script:AI_Form.Close()
    })

    function script:Finish-InstallRun {
        param([bool]$Cancelled)

        $script:AI_InstallButton.Enabled = (Test-IsAdministrator)
        $script:AI_ScanButton.Enabled = $true
        $script:AI_BrowseButton.Enabled = $true
        $script:AI_TempButton.Enabled = $true
        $script:AI_CancelButton.Enabled = $false
        $script:AI_CommonSwitchCheck.Enabled = $true
        $script:AI_FallbackCheck.Enabled = $true
        $script:AI_RecursiveCheck.Enabled = $true
        if ($Cancelled) {
            Add-Log "Cancelled."
            $script:AI_StatusLabel.Text = "Cancelled."
        } else {
            $script:AI_StatusLabel.Text = "Finished. Check the log."
        }
    }

    $installButton.Add_Click({
        if (-not (Test-IsAdministrator)) {
            [System.Windows.Forms.MessageBox]::Show("Please restart as administrator before installing.", "Folder Auto Installer") | Out-Null
            return
        }
        if ($script:Installers.Count -eq 0) {
            Scan-Folder
        }
        if ($script:Installers.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No .msi, .exe, or .msu installers found.", "Folder Auto Installer") | Out-Null
            return
        }

        $script:AI_InstallButton.Enabled = $false
        $script:AI_ScanButton.Enabled = $false
        $script:AI_BrowseButton.Enabled = $false
        $script:AI_TempButton.Enabled = $false
        $script:AI_CancelButton.Enabled = $true
        $script:AI_CommonSwitchCheck.Enabled = $false
        $script:AI_FallbackCheck.Enabled = $false
        $script:AI_RecursiveCheck.Enabled = $false
        $script:AI_StatusLabel.Text = "Installing..."

        $script:AI_CancelRequested = $false
        $tryCommon = [bool]$script:AI_CommonSwitchCheck.Checked
        $fallback = [bool]$script:AI_FallbackCheck.Checked
        $failFolder = Join-Path $script:AI_FolderText.Text.Trim() "Fail"
        $cancelled = $false
        $successfulApps = New-Object System.Collections.Generic.List[string]
        $failedApps = New-Object System.Collections.Generic.List[string]
        $silentLog = { param($m) }
        Add-Log ""
        Add-Log ("Installation started: {0} installer(s)." -f $script:Installers.Count)

        for ($i = 0; $i -lt $script:Installers.Count; $i++) {
            if ($script:AI_CancelRequested) {
                $cancelled = $true
                break
            }

            $entry = $script:Installers[$i]
            Add-Log ("INSTALLING ({0}/{1}): {2}" -f ($i + 1), $script:Installers.Count, $entry.Name)
            try {
                $exitCode = Invoke-Installer -Path $entry.Path -Type $entry.Type -TryCommonSwitches:$tryCommon -InteractiveFallback:$fallback -Log $silentLog
                if ($exitCode -eq 0 -or $exitCode -eq 3010) {
                    [void]$successfulApps.Add($entry.Name)
                    if ($exitCode -eq 3010) {
                        Add-Log ("SUCCESS: {0} (reboot required)" -f $entry.Name)
                    } else {
                        Add-Log ("SUCCESS: {0}" -f $entry.Name)
                    }
                } else {
                    [void]$failedApps.Add($entry.Name)
                    [void](Move-FailedInstaller -Path $entry.Path -FailFolder $failFolder -Log $silentLog)
                    Add-Log ("FAILED: {0}" -f $entry.Name)
                }
            } catch {
                [void]$failedApps.Add($entry.Name)
                [void](Move-FailedInstaller -Path $entry.Path -FailFolder $failFolder -Log $silentLog)
                Add-Log ("FAILED: {0}" -f $entry.Name)
            }
            if (-not $script:AI_CancelRequested -and ($i + 1) -lt $script:Installers.Count) {
                Add-Log ("NEXT: {0}" -f $script:Installers[$i + 1].Name)
            }
            [System.Windows.Forms.Application]::DoEvents()
        }

        Add-Log ""
        Add-Log "Summary"
        Add-Log ("Successful ({0}):" -f $successfulApps.Count)
        if ($successfulApps.Count -eq 0) {
            Add-Log "  None"
        } else {
            foreach ($name in $successfulApps) { Add-Log ("  {0}" -f $name) }
        }
        Add-Log ("Failed ({0}):" -f $failedApps.Count)
        if ($failedApps.Count -eq 0) {
            Add-Log "  None"
        } else {
            foreach ($name in $failedApps) { Add-Log ("  {0}" -f $name) }
        }

        Finish-InstallRun -Cancelled:$cancelled
    })

    $cancelButton.Add_Click({
        $script:AI_CancelRequested = $true
        Add-Log "Cancel requested."
    })

    Update-AdminState
    if ($InitialFolder -and (Test-Path -LiteralPath $InitialFolder -PathType Container)) {
        Scan-Folder
    }

    return $form
}

$form = New-Form
[void][System.Windows.Forms.Application]::Run($form)
