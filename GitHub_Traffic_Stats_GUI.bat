<# ::

    cls & @echo off & title GitHub_Traffic_Stats_GUI
    copy /y "%~f0" "%TEMP%\%~n0.ps1" >NUL && powershell -Nologo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%TEMP%\%~n0.ps1"
    exit /b

#>


################################################################################
# GitHub Traffic Stats
# Author: Freenitial on GitHub
# Version : 0.7
################################################################################

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

################################################################################
# GLOBAL VARIABLES
################################################################################

$Script:LocalAppDataDir = Join-Path $env:LOCALAPPDATA "GitHub_Traffic_Stats_GUI"
if (!(Test-Path $Script:LocalAppDataDir)) {
    New-Item -ItemType Directory -Force -Path $Script:LocalAppDataDir | Out-Null
}
$Script:AuthFilePath   = Join-Path $Script:LocalAppDataDir "auth.txt"
$Script:LocalDataFile  = Join-Path $Script:LocalAppDataDir "TrafficData.json"

$Script:GitHubUsername = $null
$Script:GitHubToken    = $null
$Script:AllReposStats  = @()

# false => "14 Days", true => "All Time"
$Script:DisplayAllTime = $false

$Script:GlobalUI       = $null
$script:btnMin = $null
$script:btnMax = $null 
$script:btnClose = $null

################################################################################
# HELPER FUNCTIONS
################################################################################

function Normalize-DailyArray {
    param([array]$Arr)
    $out = @()
    foreach ($item in $Arr) {
        if (-not $item) { continue }
        # Ensure PSCustomObject
        $obj = $item | Select-Object *
        # Check timestamp
        if (-not $obj.timestamp) { continue }
        # Ensure count / uniques
        if (-not $obj.PSObject.Properties.Name -contains 'count') {
            Add-Member -InputObject $obj -NotePropertyName 'count' -NotePropertyValue 0
        }
        if (-not $obj.PSObject.Properties.Name -contains 'uniques') {
            Add-Member -InputObject $obj -NotePropertyName 'uniques' -NotePropertyValue 0
        }
        $out += $obj
    }
    return $out
}

function Normalize-RepoStats {
    param([PSCustomObject]$Repo)
    if (-not $Repo) { return $null }
    $r = $Repo | Select-Object *
    $r.ViewsDaily   = Normalize-DailyArray $r.ViewsDaily
    $r.ClonesDaily  = Normalize-DailyArray $r.ClonesDaily
    if (-not $r.PopularReferrers) { $r.PopularReferrers = @() }

    # Recalculate totals
    $r.TotalViews   = ($r.ViewsDaily  | Measure-Object -Property count   -Sum).Sum
    $r.UniqueViews  = ($r.ViewsDaily  | Measure-Object -Property uniques -Sum).Sum
    $r.TotalClones  = ($r.ClonesDaily | Measure-Object -Property count   -Sum).Sum
    $r.UniqueClones = ($r.ClonesDaily | Measure-Object -Property uniques -Sum).Sum

    return $r
}

################################################################################
# CREDENTIALS
################################################################################

function Test-GitHubCredentials {
    param([string]$Username,[string]$Token)
    $testUri = "https://api.github.com/user/repos?per_page=1"
    try {
        $headers = @{
            Authorization = ("Basic " + [System.Convert]::ToBase64String(
                [System.Text.Encoding]::ASCII.GetBytes("$Username`:$Token")
            ))
            'User-Agent'   = "GitStats-PowerShell"
        }
        $response = Invoke-RestMethod -Uri $testUri -Headers $headers -Method Get -ErrorAction Stop
        if ($response) { return $true } else { return $false }
    }
    catch {
        return $false
    }
}

function Save-GitHubCredentialsToFile {
    param([string]$Username,[string]$Token,[string]$FilePath)
    $content = "[GitStatsAuth]`r`nusername=$Username`r`ntoken=$Token"
    Set-Content -Path $FilePath -Value $content -Force
}

function Load-GitHubCredentialsFromFile {
    param([string]$FilePath)
    if (!(Test-Path $FilePath)) { return $false }
    try {
        $lines = Get-Content -Path $FilePath
        foreach ($line in $lines) {
            if ($line -match "^username=(.*)") {
                $Script:GitHubUsername = $Matches[1]
            }
            elseif ($line -match "^token=(.*)") {
                $Script:GitHubToken = $Matches[1]
            }
        }
        return $true
    }
    catch {
        return $false
    }
}

################################################################################
# LOCAL CACHE
################################################################################

function Load-LocalTrafficCache {
    if (Test-Path $Script:LocalDataFile) {
        try {
            $json = Get-Content -Path $Script:LocalDataFile -Raw
            if ($json -and $json.Trim()) {
                $data = $json | ConvertFrom-Json
                return $data
            }
        }
        catch { }
    }
    return @()
}

function Save-LocalTrafficCache {
    param([array]$AllData)
    $json = $AllData | ConvertTo-Json -Depth 10
    Set-Content -Path $Script:LocalDataFile -Value $json -Force
}

################################################################################
# MERGE
################################################################################

function Merge-DailyArrays {
    param([array]$OldArr,[array]$NewArr)
    if (-not $OldArr) { return $NewArr }
    if (-not $NewArr) { return $OldArr }

    $oldNorm = $OldArr | ForEach-Object { Normalize-DailyArray @($_) }
    $newNorm = $NewArr | ForEach-Object { Normalize-DailyArray @($_) }

    $map = @{}
    foreach ($v in $oldNorm) {
        $key = ([DateTime]$v.timestamp).ToString("yyyy-MM-dd")
        $map[$key] = $v
    }
    foreach ($v in $newNorm) {
        $key = ([DateTime]$v.timestamp).ToString("yyyy-MM-dd")
        $map[$key] = $v  # override
    }
    return $map.Values | Sort-Object { [DateTime]$_.timestamp }
}

function Merge-Referrers {
    param([array]$OldArr,[array]$NewArr)
    if (-not $OldArr) { return $NewArr }
    if (-not $NewArr) { return $OldArr }
    $map = @{}
    foreach ($r in $OldArr) {
        if ($r) {
            $map[$r.referrer] = $r
        }
    }
    foreach ($r in $NewArr) {
        if ($r) {
            $ref = $r.referrer
            if ($map.ContainsKey($ref)) {
                $map[$ref].count   += $r.count
                $map[$ref].uniques += $r.uniques
            }
            else {
                $map[$ref] = $r
            }
        }
    }
    return $map.Values
}

function Merge-TrafficData {
    param([array]$LocalData,[array]$NewData)
    $localMap = @{}
    foreach ($repo in $LocalData) {
        $rNorm = Normalize-RepoStats $repo
        if ($rNorm) {
            $localMap[$rNorm.RepoName] = $rNorm
        }
    }

    foreach ($repoNew in $NewData) {
        $rNormNew = Normalize-RepoStats $repoNew
        if (-not $rNormNew) { continue }

        $name = $rNormNew.RepoName
        if ($localMap.ContainsKey($name)) {
            $ex = $localMap[$name]
            $mergedViews = Merge-DailyArrays $ex.ViewsDaily  $rNormNew.ViewsDaily
            $mergedClones= Merge-DailyArrays $ex.ClonesDaily $rNormNew.ClonesDaily
            $mergedRefs  = Merge-Referrers   $ex.PopularReferrers $rNormNew.PopularReferrers

            $ex.ViewsDaily        = $mergedViews
            $ex.ClonesDaily       = $mergedClones
            $ex.PopularReferrers  = $mergedRefs

            $ex.TotalViews   = ($mergedViews  | Measure-Object -Property count   -Sum).Sum
            $ex.UniqueViews  = ($mergedViews  | Measure-Object -Property uniques -Sum).Sum
            $ex.TotalClones  = ($mergedClones | Measure-Object -Property count   -Sum).Sum
            $ex.UniqueClones = ($mergedClones | Measure-Object -Property uniques -Sum).Sum

            $localMap[$name] = $ex
        }
        else {
            $localMap[$name] = $rNormNew
        }
    }
    return $localMap.Values
}

################################################################################
# GITHUB API
################################################################################

function Get-GitHubRepositories {
    Write-Host "[DEBUG] Retrieving repos..."
    $repos = @()
    $page = 1
    $headers = @{
        Authorization = ("Basic " + [System.Convert]::ToBase64String(
            [System.Text.Encoding]::ASCII.GetBytes("$($Script:GitHubUsername):$($Script:GitHubToken)")
        ))
        'User-Agent'   = "GitStats-PowerShell"
    }
    while ($true) {
        $uri = "https://api.github.com/user/repos?visibility=all&per_page=100&page=$page"
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        if ($response.Count -eq 0) { break }
        $repos += $response
        $page++
    }
    Write-Host "[DEBUG] Found repos: $($repos.Count)"
    return $repos
}

function Get-GitHubTrafficStatsForRepo {
    param([string]$Owner,[string]$RepoName)
    $headers = @{
        Authorization = ("Basic " + [System.Convert]::ToBase64String(
            [System.Text.Encoding]::ASCII.GetBytes("$($Script:GitHubUsername):$($Script:GitHubToken)")
        ))
        'User-Agent'   = "GitStats-PowerShell"
    }
    $viewsUri  = "https://api.github.com/repos/$Owner/$RepoName/traffic/views"
    $clonesUri = "https://api.github.com/repos/$Owner/$RepoName/traffic/clones"
    $refsUri   = "https://api.github.com/repos/$Owner/$RepoName/traffic/popular/referrers"

    $viewsResponse  = Invoke-RestMethod -Uri $viewsUri  -Headers $headers -Method Get
    $clonesResponse = Invoke-RestMethod -Uri $clonesUri -Headers $headers -Method Get
    $refsResp       = Invoke-RestMethod -Uri $refsUri   -Headers $headers -Method Get

    [PSCustomObject]@{
        RepoName         = $RepoName
        TotalViews       = $viewsResponse.count
        UniqueViews      = $viewsResponse.uniques
        TotalClones      = $clonesResponse.count
        UniqueClones     = $clonesResponse.uniques
        ViewsDaily       = $viewsResponse.views
        ClonesDaily      = $clonesResponse.clones
        PopularReferrers = $refsResp
    }
}

################################################################################
# BUILD UI
################################################################################

function Build-LoginForm {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "GitHub Traffic Stats GUI - Login"
    $f.Size = New-Object System.Drawing.Size(400,200)
    $f.StartPosition = "CenterScreen"
    $f.FormBorderStyle = "FixedDialog"
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.BackColor = [System.Drawing.Color]::FromArgb(45,45,45)
    $f.ForeColor = [System.Drawing.Color]::White

    $lblU = New-Object System.Windows.Forms.Label
    $lblU.Text = "GitHub Username:"
    $lblU.Left = 20; $lblU.Top = 20
    $lblU.AutoSize = $true
    $f.Controls.Add($lblU)

    $txtU = New-Object System.Windows.Forms.TextBox
    $txtU.Left = 150; $txtU.Top = 18
    $txtU.Width = 200
    $txtU.BackColor = [System.Drawing.Color]::FromArgb(64,64,64)
    $txtU.ForeColor = [System.Drawing.Color]::White
    $f.Controls.Add($txtU)

    $lblT = New-Object System.Windows.Forms.Label
    $lblT.Text = "GitHub Token:"
    $lblT.Left = 20; $lblT.Top = 60
    $lblT.AutoSize = $true
    $f.Controls.Add($lblT)

    $txtT = New-Object System.Windows.Forms.TextBox
    $txtT.Left = 150; $txtT.Top = 58
    $txtT.Width = 200
    $txtT.BackColor = [System.Drawing.Color]::FromArgb(64,64,64)
    $txtT.ForeColor = [System.Drawing.Color]::White
    $txtT.UseSystemPasswordChar = $true
    $f.Controls.Add($txtT)

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "OK"
    $btnOK.Left = 150; $btnOK.Top = 110
    $btnOK.BackColor = [System.Drawing.Color]::FromArgb(100,100,100)
    $btnOK.ForeColor = [System.Drawing.Color]::White
    $btnOK.Add_Click({
        if (Test-GitHubCredentials $txtU.Text $txtT.Text) {
            Save-GitHubCredentialsToFile $txtU.Text $txtT.Text $Script:AuthFilePath
            $Script:GitHubUsername = $txtU.Text
            $Script:GitHubToken    = $txtT.Text
            $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $f.Close()
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Invalid credentials","Error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })
    $f.Controls.Add($btnOK)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Left = 250; $btnCancel.Top = 110
    $btnCancel.BackColor = [System.Drawing.Color]::FromArgb(100,100,100)
    $btnCancel.ForeColor = [System.Drawing.Color]::White
    $btnCancel.Add_Click({
        $f.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $f.Close()
    })
    $f.Controls.Add($btnCancel)

    return $f.ShowDialog()
}

function Update-TitleBarButtons {
	param($form, $titleBar)
	$formWidth = $form.Width
	
	$btnMin = $titleBar.Controls | Where-Object { $_.Text -eq "-" }
	$btnMax = $titleBar.Controls | Where-Object { $_.Text -eq "□" }
	$btnClose = $titleBar.Controls | Where-Object { $_.Text -eq "X" }
	
	if ($btnMin -and $btnMax -and $btnClose) {
		$btnClose.Left = $formWidth - 50
		$btnMax.Left = $formWidth - 95
		$btnMin.Left = $formWidth - 140
	}
}

function Build-GlobalForm {
    $main = New-Object ResizableForm
    $main.Text = "GitHub Traffic Stats GUI"
    $main.StartPosition = "CenterScreen"
    $main.Width = 850; $main.Height = 600
    $main.MinimumSize = New-Object System.Drawing.Size(850, 528)
    $main.BackColor = [System.Drawing.Color]::FromArgb(45,45,45)
    $main.ForeColor = [System.Drawing.Color]::White
    $main.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddRectangle($main.ClientRectangle)
    $main.Region = New-Object System.Drawing.Region($path)

    # Helper function for titlebar buttons
	function Add-TitleBarButton($form, $titleBar, $text, $size, $rightOffset, $onClick) {
		$button = New-Object System.Windows.Forms.Button
		$button.Text = $text
		$button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
		$button.FlatAppearance.BorderSize = 0
		$button.BackColor = [System.Drawing.Color]::Transparent
		$button.ForeColor = [System.Drawing.Color]::White
		$button.Font = [System.Drawing.Font]::new("Arial", 10, [System.Drawing.FontStyle]::Bold)
		$button.Size = [System.Drawing.Size]::new($size[0], $size[1])
		$button.Location = [System.Drawing.Point]::new($form.Width - $rightOffset, 0)
		$button.Add_Click($onClick)
		
		if ($text -eq "X") {
			$button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Red
		} else {
			$button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(64,64,64)
		}
		
		$titleBar.Controls.Add($button)
		switch($text) {
			"-" { $script:btnMin = $button }
			"□" { $script:btnMax = $button }
			"X" { $script:btnClose = $button }
		}
		return $button
	}

    # Title bar setup
    $titleBar = New-Object System.Windows.Forms.Panel
    $titleBar.Dock = [System.Windows.Forms.DockStyle]::Top
    $titleBar.Height = 30

    $titleBar.Add_Paint({
        param($sender, $e)
        $rect = $sender.ClientRectangle
        
        $gradientBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $rect,
            [System.Drawing.Color]::FromArgb(35, 35, 38),
            [System.Drawing.Color]::FromArgb(18, 18, 20),
            [System.Drawing.Drawing2D.LinearGradientMode]::Vertical
        )
        
        $colorBlend = New-Object System.Drawing.Drawing2D.ColorBlend(4)
        $colorBlend.Colors = @(
            [System.Drawing.Color]::FromArgb(35, 35, 38),
            [System.Drawing.Color]::FromArgb(30, 30, 33),
            [System.Drawing.Color]::FromArgb(25, 25, 28),
            [System.Drawing.Color]::FromArgb(18, 18, 20)
        )
        $colorBlend.Positions = @([float]0.0, [float]0.3, [float]0.7, [float]1.0)
        $gradientBrush.InterpolationColors = $colorBlend
        
        $e.Graphics.FillRectangle($gradientBrush, $rect)
        
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 60, 60))
        $e.Graphics.DrawLine($pen, 0, $rect.Height - 1, $rect.Width, $rect.Height - 1)
        
        $pen.Dispose()
        $gradientBrush.Dispose()
    })

    # Title label
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "GitHub Traffic Stats GUI"
    $titleLabel.ForeColor = [System.Drawing.Color]::White
    $titleLabel.Font = [System.Drawing.Font]::new("Arial", 12, [System.Drawing.FontStyle]::Bold)
    $titleLabel.AutoSize = $true
    $titleLabel.Location = [System.Drawing.Point]::new(10, 5)
    $titleLabel.BackColor = [System.Drawing.Color]::Transparent
    $titleBar.Controls.Add($titleLabel)

    # Add control buttons
	$btnMin = Add-TitleBarButton $main $titleBar "-" @(45, 30) 160 {
		param($sender, $e)
		$sender.Parent.Parent.WindowState = [System.Windows.Forms.FormWindowState]::Minimized 
	}

	$btnMax = Add-TitleBarButton $main $titleBar "□" @(45, 30) 115 {
		param($sender, $e)
		$form = $sender.Parent.Parent
		if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
			$form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
		} else {
			$form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
		}
	}

	$btnClose = Add-TitleBarButton $main $titleBar "X" @(45, 30) 70 {
		param($sender, $e)
		$sender.Parent.Parent.Close() 
	}

	# Add resize handler
	$main.Add_Resize({
		if ($script:btnMin -and $script:btnMax -and $script:btnClose) {
			$width = $this.Width
			$script:btnClose.Left = $width - 70
			$script:btnMax.Left = $width - 115
			$script:btnMin.Left = $width - 160
		}
	})

    # Window drag functionality
    $titleBar.Add_MouseDown({ 
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $form = $sender.Parent
            $script:isDragging = $true
            $script:offset = $form.PointToScreen($e.Location)
            $script:offset.X -= $form.Left
            $script:offset.Y -= $form.Top
        }
    })

    $titleBar.Add_MouseMove({ 
        param($sender, $e)
        if ($script:isDragging) {
            $form = $sender.Parent
            $newPoint = $sender.PointToScreen($e.Location)
            $form.Location = New-Object System.Drawing.Point(
                ($newPoint.X - $script:offset.X),
                ($newPoint.Y - $script:offset.Y)
            )
        }
    })

    $titleBar.Add_MouseUp({ 
        $script:isDragging = $false 
    })
	

    # SplitContainer first
	$split = New-Object System.Windows.Forms.SplitContainer
	$split.Dock = 'Fill'
	$split.Orientation=[System.Windows.Forms.Orientation]::Horizontal
	$split.BorderStyle='Fixed3D'
	$split.BackColor=[System.Drawing.Color]::Gray
	$split.MinimumSize = New-Object System.Drawing.Size(0, 400) # Au moins 400px de haut (200+200)
	$split.Panel1MinSize = 200
	$split.Panel2MinSize = 200
	$split.SplitterWidth=8
	$split.SplitterDistance=300
	$main.Controls.Add($split)

    # Top panel last (it will be on top due to Z-order)
    $panelTop = New-Object System.Windows.Forms.Panel
    $panelTop.Dock = 'Top'
    $panelTop.Height = 60
    $panelTop.BackColor = [System.Drawing.Color]::FromArgb(45,45,45)
    $main.Controls.Add($panelTop)

    # Buttons
    $btnReset = New-Object System.Windows.Forms.Button
    $btnReset.Text = "Reset Login"
    $btnReset.Left = 10; $btnReset.Top = 15
    $btnReset.Width = 100; $btnReset.Height = 30
    $btnReset.BackColor = [System.Drawing.Color]::FromArgb(100,100,100)
    $btnReset.ForeColor = [System.Drawing.Color]::White
    $panelTop.Controls.Add($btnReset)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"
    $btnRefresh.Left = $btnReset.Right + 5; $btnRefresh.Top=15
    $btnRefresh.Width=80; $btnRefresh.Height=30
    $btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(100,100,100)
    $btnRefresh.ForeColor = [System.Drawing.Color]::White
    $panelTop.Controls.Add($btnRefresh)

    $rb14 = New-Object System.Windows.Forms.RadioButton
    $rb14.Text = "14 Days"
    $rb14.Left = $btnRefresh.Right + 20; $rb14.Top=20
    $rb14.Width=70; $rb14.Height=20
    $rb14.ForeColor=[System.Drawing.Color]::White
    $rb14.BackColor=[System.Drawing.Color]::FromArgb(45,45,45)
    $rb14.Checked=$true
    $panelTop.Controls.Add($rb14)

    $rbAll = New-Object System.Windows.Forms.RadioButton
    $rbAll.Text="All Time"
    $rbAll.Left=$rb14.Right+5; $rbAll.Top=20
    $rbAll.Width=80; $rbAll.Height=20
    $rbAll.ForeColor=[System.Drawing.Color]::White
    $rbAll.BackColor=[System.Drawing.Color]::FromArgb(45,45,45)
    $panelTop.Controls.Add($rbAll)

    $prog = New-Object System.Windows.Forms.ProgressBar
    $prog.Left = $rbAll.Right + 20
    $prog.Top = 15
    $prog.Width=400; $prog.Height=30
    $prog.Style='Continuous'
    $panelTop.Controls.Add($prog)

    # Main DGV
    $dgvGlobal = New-Object System.Windows.Forms.DataGridView
	$dgvGlobal.MultiSelect = $false
    $dgvGlobal.Dock='Fill'
    $dgvGlobal.BackgroundColor=[System.Drawing.Color]::FromArgb(60,60,60)
    $dgvGlobal.DefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(60,60,60)
    $dgvGlobal.DefaultCellStyle.ForeColor=[System.Drawing.Color]::White
    $dgvGlobal.ColumnHeadersDefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(45,45,45)
    $dgvGlobal.ColumnHeadersDefaultCellStyle.ForeColor=[System.Drawing.Color]::White
    $dgvGlobal.EnableHeadersVisualStyles=$false
    $dgvGlobal.RowHeadersVisible=$false
    $dgvGlobal.GridColor=[System.Drawing.Color]::DarkGray
    $dgvGlobal.AutoGenerateColumns=$false
    $dgvGlobal.AllowUserToAddRows=$false
    $dgvGlobal.ReadOnly=$true
    $dgvGlobal.SelectionMode='FullRowSelect'
    $dgvGlobal.AutoSizeColumnsMode='Fill'
    $dgvGlobal.AutoSizeRowsMode='None'
    $dgvGlobal.AllowUserToResizeRows=$false

    # Columns with FillWeight to ensure first column is double
    $colRepo = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colRepo.HeaderText="Repository"
    $colRepo.AutoSizeMode='Fill'
    $colRepo.FillWeight=370

    $colViews = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colViews.HeaderText="Total Views"
    $colViews.AutoSizeMode='Fill'
    $colViews.FillWeight=100

    $colUniV = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colUniV.HeaderText="Unique Views"
    $colUniV.AutoSizeMode='Fill'
    $colUniV.FillWeight=100

    $colClone= New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colClone.HeaderText="Total Clones"
    $colClone.AutoSizeMode='Fill'
    $colClone.FillWeight=100

    $colUniC= New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colUniC.HeaderText="Unique Clones"
    $colUniC.AutoSizeMode='Fill'
    $colUniC.FillWeight=100

    $dgvGlobal.Columns.AddRange($colRepo,$colViews,$colUniV,$colClone,$colUniC)
    $split.Panel1.Controls.Add($dgvGlobal)

    # Bottom details (Label + 2 DGV)
    $tableDetail = New-Object System.Windows.Forms.TableLayoutPanel
    $tableDetail.Dock='Fill'
    $tableDetail.RowCount=3
    $tableDetail.ColumnCount=1
    $tableDetail.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $tableDetail.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,50)))
    $tableDetail.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,50)))
    $split.Panel2.Controls.Add($tableDetail)

    $lblRepoName = New-Object System.Windows.Forms.Label
    $lblRepoName.Text="No repo selected"
    $lblRepoName.AutoSize=$false
    $lblRepoName.Dock='Fill'
    $lblRepoName.TextAlign='MiddleCenter'
    $lblRepoName.Font=New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
    $lblRepoName.ForeColor=[System.Drawing.Color]::White
    $lblRepoName.BackColor=[System.Drawing.Color]::FromArgb(70,70,70)
    $lblRepoName.Padding='5,5,5,5'
    $tableDetail.Controls.Add($lblRepoName,0,0)

    # DGV for daily
    $dgvDaily = New-Object System.Windows.Forms.DataGridView
    $dgvDaily.Dock='Fill'
	$dgvDaily.BackgroundColor=[System.Drawing.Color]::FromArgb(70,70,70)
	$dgvDaily.DefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(70,70,70)
    $dgvDaily.DefaultCellStyle.ForeColor=[System.Drawing.Color]::White
    $dgvDaily.ColumnHeadersDefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(60,60,60)
    $dgvDaily.ColumnHeadersDefaultCellStyle.ForeColor=[System.Drawing.Color]::White
    $dgvDaily.EnableHeadersVisualStyles=$false
    $dgvDaily.RowHeadersVisible=$false
    $dgvDaily.GridColor=[System.Drawing.Color]::DarkGray
    $dgvDaily.AutoGenerateColumns=$false
    $dgvDaily.AllowUserToAddRows=$false
    $dgvDaily.ReadOnly=$true
    $dgvDaily.SelectionMode='FullRowSelect'
    $dgvDaily.MultiSelect = $false
    $dgvDaily.RowsDefaultCellStyle.SelectionBackColor = $dgvDaily.DefaultCellStyle.BackColor
    $dgvDaily.RowsDefaultCellStyle.SelectionForeColor = $dgvDaily.DefaultCellStyle.ForeColor
	$dgvDaily.Add_SelectionChanged({ 
		param($sender, $e)
		$sender.ClearSelection()
	})
    $dgvDaily.AutoSizeColumnsMode='Fill'
    $dgvDaily.AutoSizeRowsMode='None'
    $dgvDaily.AllowUserToResizeRows=$false
    $tableDetail.Controls.Add($dgvDaily,0,1)

    # Daily columns
    $colDate   = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDate.HeaderText="Date"
    $colDayV   = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDayV.HeaderText="Daily Views"
    $colDayUni = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDayUni.HeaderText="Unique Views"
    $colDayC   = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDayC.HeaderText="Daily Clones"
    $colDayUniC= New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDayUniC.HeaderText="Unique Clones"
    $dgvDaily.Columns.AddRange($colDate,$colDayV,$colDayUni,$colDayC,$colDayUniC)

    # DGV for referrers
    $dgvRef = New-Object System.Windows.Forms.DataGridView
    $dgvRef.Dock='Fill'
	$dgvRef.BackgroundColor=[System.Drawing.Color]::FromArgb(70,70,70)
	$dgvRef.DefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(70,70,70)
    $dgvRef.DefaultCellStyle.ForeColor=[System.Drawing.Color]::White
    $dgvRef.ColumnHeadersDefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(60,60,60)
    $dgvRef.ColumnHeadersDefaultCellStyle.ForeColor=[System.Drawing.Color]::White
    $dgvRef.EnableHeadersVisualStyles=$false
    $dgvRef.RowHeadersVisible=$false
    $dgvRef.GridColor=[System.Drawing.Color]::DarkGray
    $dgvRef.AutoGenerateColumns=$false
    $dgvRef.AllowUserToAddRows=$false
    $dgvRef.ReadOnly=$true
    $dgvRef.SelectionMode='FullRowSelect'
    $dgvRef.MultiSelect = $false
    $dgvRef.RowsDefaultCellStyle.SelectionBackColor = $dgvRef.DefaultCellStyle.BackColor
    $dgvRef.RowsDefaultCellStyle.SelectionForeColor = $dgvRef.DefaultCellStyle.ForeColor
	$dgvRef.Add_SelectionChanged({ 
		param($sender, $e)
		$sender.ClearSelection()
	})
    $dgvRef.AutoSizeColumnsMode='Fill'
    $dgvRef.AutoSizeRowsMode='None'
    $dgvRef.AllowUserToResizeRows=$false
    $tableDetail.Controls.Add($dgvRef,0,2)

    # Referrer columns
	$colRef = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
	$colRef.HeaderText="Referrer"
	$colRef.AutoSizeMode='Fill'
	$colRef.FillWeight=300

	$colRefCnt = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
	$colRefCnt.HeaderText="Count"
	$colRefCnt.AutoSizeMode='Fill'
	$colRefCnt.FillWeight=100

	$colRefUnq = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
	$colRefUnq.HeaderText="Uniques"
	$colRefUnq.AutoSizeMode='Fill'
	$colRefUnq.FillWeight=100

	$dgvRef.Columns.AddRange($colRef,$colRefCnt,$colRefUnq)
	
	$main.Controls.Add($titleBar)

    return [PSCustomObject]@{
        Form        = $main
        PanelTop    = $panelTop
        BtnReset    = $btnReset
        BtnRefresh  = $btnRefresh
        Rb14Days    = $rb14
        RbAllTime   = $rbAll
        ProgressBar = $prog
        Split       = $split
        DataGrid    = $dgvGlobal
        DailyGrid   = $dgvDaily
        RefGrid     = $dgvRef
        LblRepoName = $lblRepoName
    }
}


################################################################################
# POPULATE DETAILS
################################################################################

function Populate-Details {
    param(
        [PSCustomObject]$RepoStats,
        [System.Windows.Forms.DataGridView]$DgvDaily,
        [System.Windows.Forms.DataGridView]$DgvReferrers,
        [System.Windows.Forms.Label]$LblRepoName
    )
    if (-not $RepoStats) {
        $LblRepoName.Text = "No repo selected"
        $DgvDaily.Rows.Clear()
        $DgvReferrers.Rows.Clear()
        return
    }
    $LblRepoName.Text = "Details for: $($RepoStats.RepoName)"
    $DgvDaily.Rows.Clear()
    $DgvReferrers.Rows.Clear()

    $norm = Normalize-RepoStats $RepoStats

    # Combine daily views/clones by date
    $map = @{}
    foreach ($v in $norm.ViewsDaily) {
        $dkey = ([DateTime]$v.timestamp).ToString("yyyy-MM-dd")
        if (-not $map.ContainsKey($dkey)) {
            $map[$dkey] = [PSCustomObject]@{ Timestamp=$dkey; ViewsCount=0; ViewsUniques=0; ClonesCount=0; ClonesUniques=0 }
        }
        $map[$dkey].ViewsCount   = $v.count
        $map[$dkey].ViewsUniques = $v.uniques
    }
    foreach ($c in $norm.ClonesDaily) {
        $dkey = ([DateTime]$c.timestamp).ToString("yyyy-MM-dd")
        if (-not $map.ContainsKey($dkey)) {
            $map[$dkey] = [PSCustomObject]@{ Timestamp=$dkey; ViewsCount=0; ViewsUniques=0; ClonesCount=0; ClonesUniques=0 }
        }
        $map[$dkey].ClonesCount   = $c.count
        $map[$dkey].ClonesUniques = $c.uniques
    }

    $sorted = $map.Values | Sort-Object { [DateTime]$_.Timestamp }
    foreach ($s in $sorted) {
        $r = $DgvDaily.Rows.Add()
        $DgvDaily.Rows[$r].Cells[0].Value = $s.Timestamp
        $DgvDaily.Rows[$r].Cells[1].Value = $s.ViewsCount
        $DgvDaily.Rows[$r].Cells[2].Value = $s.ViewsUniques
        $DgvDaily.Rows[$r].Cells[3].Value = $s.ClonesCount
        $DgvDaily.Rows[$r].Cells[4].Value = $s.ClonesUniques
    }
    # Clear selection after filling
    $DgvDaily.ClearSelection()

    # Populate referrers
    foreach ($ref in $norm.PopularReferrers) {
        if ($ref) {
            $idx = $DgvReferrers.Rows.Add()
            $DgvReferrers.Rows[$idx].Cells[0].Value = $ref.referrer
            $DgvReferrers.Rows[$idx].Cells[1].Value = $ref.count
            $DgvReferrers.Rows[$idx].Cells[2].Value = $ref.uniques
        }
    }
    # Clear selection after filling
    $DgvReferrers.ClearSelection()
}

################################################################################
# REFRESH GLOBAL GRID
################################################################################

function Refresh-GlobalGrid {
    $dgv = $Script:GlobalUI.DataGrid
    $dgv.Rows.Clear()

    $listFinal = @()
    foreach ($repo in $Script:AllReposStats) {
        if (-not $repo) { continue }
        $rFix = Normalize-RepoStats $repo
        if (-not $Script:DisplayAllTime) {
            $cutDate = (Get-Date).AddDays(-14)
            $v14 = $rFix.ViewsDaily  | Where-Object { 
                if ($_.timestamp) {
                    $dateVal = [DateTime]$_.timestamp
                    $dateVal -ge $cutDate
                }
            }
            $c14 = $rFix.ClonesDaily | Where-Object {
                if ($_.timestamp) {
                    $dateVal = [DateTime]$_.timestamp
                    $dateVal -ge $cutDate
                }
            }
            $rFix.TotalViews   = ($v14 | Measure-Object -Property count   -Sum).Sum
            $rFix.UniqueViews  = ($v14 | Measure-Object -Property uniques -Sum).Sum
            $rFix.TotalClones  = ($c14 | Measure-Object -Property count   -Sum).Sum
            $rFix.UniqueClones = ($c14 | Measure-Object -Property uniques -Sum).Sum
        }
        $listFinal += $rFix
    }

    foreach ($repoItem in $listFinal) {
        $row = $dgv.Rows.Add()
        $dgv.Rows[$row].Cells[0].Value = $repoItem.RepoName
        $dgv.Rows[$row].Cells[1].Value = $repoItem.TotalViews
        $dgv.Rows[$row].Cells[2].Value = $repoItem.UniqueViews
        $dgv.Rows[$row].Cells[3].Value = $repoItem.TotalClones
        $dgv.Rows[$row].Cells[4].Value = $repoItem.UniqueClones
    }

    if ($listFinal.Count -gt 0) {
        $sumViews       = ($listFinal | Measure-Object -Property TotalViews   -Sum).Sum
        $sumUniqueViews = ($listFinal | Measure-Object -Property UniqueViews  -Sum).Sum
        $sumClones      = ($listFinal | Measure-Object -Property TotalClones  -Sum).Sum
        $sumUniqueClones= ($listFinal | Measure-Object -Property UniqueClones -Sum).Sum

        $rt = $dgv.Rows.Add()
        $dgv.Rows[$rt].Cells[0].Value = "Total"
        $dgv.Rows[$rt].Cells[1].Value = $sumViews
        $dgv.Rows[$rt].Cells[2].Value = $sumUniqueViews
        $dgv.Rows[$rt].Cells[3].Value = $sumClones
        $dgv.Rows[$rt].Cells[4].Value = $sumUniqueClones
    }
	
	$dgv.ClearSelection()
}

################################################################################
# PROGRESSIVE LOAD
################################################################################

function Progressive-Load {
    param([bool]$ForceAPI = $false)

    $ui = $Script:GlobalUI
    $prog = $ui.ProgressBar
    $localData = Load-LocalTrafficCache

    # Load local data into global stats
    $Script:AllReposStats = $localData

    # Show local data first
    Refresh-GlobalGrid

    if ($ForceAPI -or $localData.Count -eq 0) {
        Write-Host "[DEBUG] Progressive-Load => ForceAPI or local empty => fetch repos"
        $repos = Get-GitHubRepositories
        $prog.Value = 0
        $prog.Maximum = $repos.Count

        $count=1
        foreach ($r in $repos) {
            $owner    = if ($r.owner) { $r.owner.login } else { $Script:GitHubUsername }
            $repoName = $r.name

            $traffic = Get-GitHubTrafficStatsForRepo -Owner $owner -RepoName $repoName
            $Script:AllReposStats = Merge-TrafficData -LocalData $Script:AllReposStats -NewData @($traffic)
            Save-LocalTrafficCache $Script:AllReposStats
            Refresh-GlobalGrid

            $prog.Value = $count
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
            $count++
        }
        $prog.Value=0
    }
    else {
        Write-Host "[DEBUG] => local data is not empty and ForceAPI=false => no new fetch"
    }
}

################################################################################
# MAIN
################################################################################

function Main {
    # Constants for window resizing
    $WM_NCHITTEST = 0x0084
    $HTLEFT = 10
    $HTRIGHT = 11
    $HTTOP = 12
    $HTTOPLEFT = 13
    $HTTOPRIGHT = 14
    $HTBOTTOM = 15
    $HTBOTTOMLEFT = 16
    $HTBOTTOMRIGHT = 17

    # Add required P/Invoke and custom form class
    Add-Type -ReferencedAssemblies @(
        'System.Windows.Forms',
        'System.Drawing'
    ) -TypeDefinition @'
    using System;
    using System.Windows.Forms;
    using System.Drawing;
    using System.Runtime.InteropServices;

    public class Win32 {
        [DllImport("user32.dll")]
        public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
        
        [DllImport("user32.dll")]
        public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    }

	public class ResizableForm : Form {
		private const int WM_NCHITTEST = 0x84;
		private const int HTLEFT = 10;
		private const int HTRIGHT = 11;
		private const int HTTOP = 12;
		private const int HTTOPLEFT = 13;
		private const int HTTOPRIGHT = 14;
		private const int HTBOTTOM = 15;
		private const int HTBOTTOMLEFT = 16;
		private const int HTBOTTOMRIGHT = 17;
		private const int BORDER_WIDTH = 5;

		public ResizableForm() {
			this.FormBorderStyle = FormBorderStyle.None;
			this.Padding = new Padding(BORDER_WIDTH);
			this.Resize += new EventHandler(Form_Resize);
			UpdateFormRegion();
		}

		private void UpdateFormRegion() {
			using (var path = new System.Drawing.Drawing2D.GraphicsPath()) {
				var rect = new Rectangle(
					0,
					0,
					this.Width,
					this.Height
				);
				path.AddRectangle(rect);
				this.Region = new Region(path);
			}
		}

		private void Form_Resize(object sender, EventArgs e) {
			this.Invalidate();
			UpdateFormRegion();
		}

		protected override void OnPaint(PaintEventArgs e) {
			base.OnPaint(e);
			
			// Dessiner la bordure
			using (var pen = new Pen(Color.FromArgb(60, 60, 60), 1)) {
				var rect = new Rectangle(
					0,
					0,
					this.Width - 1,
					this.Height - 1
				);
				e.Graphics.DrawRectangle(pen, rect);
			}
		}

		protected override void WndProc(ref Message m) {
			base.WndProc(ref m);

			if (m.Msg == WM_NCHITTEST && this.WindowState != FormWindowState.Maximized) {
				var screenPoint = new Point(m.LParam.ToInt32() & 0xffff, m.LParam.ToInt32() >> 16);
				var clientPoint = this.PointToClient(screenPoint);

				if (clientPoint.Y <= BORDER_WIDTH) {
					if (clientPoint.X <= BORDER_WIDTH)
						m.Result = (IntPtr)HTTOPLEFT;
					else if (clientPoint.X >= this.Width - BORDER_WIDTH)
						m.Result = (IntPtr)HTTOPRIGHT;
					else
						m.Result = (IntPtr)HTTOP;
				}
				else if (clientPoint.Y >= this.Height - BORDER_WIDTH) {
					if (clientPoint.X <= BORDER_WIDTH)
						m.Result = (IntPtr)HTBOTTOMLEFT;
					else if (clientPoint.X >= this.Width - BORDER_WIDTH)
						m.Result = (IntPtr)HTBOTTOMRIGHT;
					else
						m.Result = (IntPtr)HTBOTTOM;
				}
				else if (clientPoint.X <= BORDER_WIDTH)
					m.Result = (IntPtr)HTLEFT;
				else if (clientPoint.X >= this.Width - BORDER_WIDTH)
					m.Result = (IntPtr)HTRIGHT;
			}
		}
	}
'@

    # Function to set window styles
    function Set-WindowLong([IntPtr]$hwnd, $index, $newStyle) {
        $win32 = [Win32]::GetWindowLong($hwnd, $index)
        [Win32]::SetWindowLong($hwnd, $index, $win32 -bor $newStyle)
    }

    # 1) Credentials
    $loaded = Load-GitHubCredentialsFromFile $Script:AuthFilePath
    if (-not $loaded) {
        $res = Build-LoginForm
        if ($res -ne [System.Windows.Forms.DialogResult]::OK) {
            return
        }
    }

    # 2) Build UI
    $ui = Build-GlobalForm
    $Script:GlobalUI = $ui

    # Add resize functionality
    $ui.Form.Add_Load({
        Set-WindowLong $this.Handle -16 0x840000
    })

    # Event: Reset
    $ui.BtnReset.Add_Click({
        if (Test-Path $Script:AuthFilePath) {
            Remove-Item $Script:AuthFilePath -Force
            [System.Windows.Forms.MessageBox]::Show("Login reset. Please restart.","Info",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
            $ui.Form.Close()
        }
    })

    # Event: Refresh => ForceAPI = true
    $ui.BtnRefresh.Add_Click({
        Progressive-Load -ForceAPI $true
    })

    # Radio 14Days
    $ui.Rb14Days.Add_CheckedChanged({
        if ($ui.Rb14Days.Checked) {
            $Script:DisplayAllTime = $false
            Refresh-GlobalGrid
        }
    })

    # Radio AllTime
    $ui.RbAllTime.Add_CheckedChanged({
        if ($ui.RbAllTime.Checked) {
            $Script:DisplayAllTime = $true
            Refresh-GlobalGrid
        }
    })

    # Event: click on main grid => load details
    $ui.DataGrid.Add_CellClick({
        param($sender,$e)
        if ($e.RowIndex -ge 0 -and $e.RowIndex -lt $sender.Rows.Count) {
            $repoName = $sender.Rows[$e.RowIndex].Cells[0].Value
            if ($repoName -eq "Total") { return }
            $found = $Script:AllReposStats | Where-Object { $_.RepoName -eq $repoName }
            if ($found) {
                Populate-Details -RepoStats $found -DgvDaily $ui.DailyGrid -DgvReferrers $ui.RefGrid -LblRepoName $ui.LblRepoName
            }
        }
    })

    # Show form and do initial load
    $ui.Form.Add_Shown({
        Progressive-Load -ForceAPI $false
    })

    [void]$ui.Form.ShowDialog()
}

Main
