[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:GcloudPath = $null
$script:GcloudReady = $false
$script:AuthReady = $false
$script:Operation = $null
$script:OperationPowerShell = $null
$script:StructuredOutput = @()
$script:BucketLocationCache = @{}
$script:MetadataOperation = $null
$script:MetadataPowerShell = $null
$script:MetadataBucket = $null

function New-IconBitmap {
    param(
        [ValidateSet('Success', 'Failure', 'Copy', 'Download')]
        [string]$Kind,
        [int]$Size = 20
    )

    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    try {
        if ($Kind -eq 'Success' -or $Kind -eq 'Failure') {
            $color = if ($Kind -eq 'Success') {
                [System.Drawing.Color]::FromArgb(28, 128, 82)
            }
            else {
                [System.Drawing.Color]::FromArgb(190, 48, 58)
            }
            $brush = New-Object System.Drawing.SolidBrush($color)
            $graphics.FillEllipse($brush, 1, 1, $Size - 2, $Size - 2)
            $brush.Dispose()

            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2.1)
            $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            if ($Kind -eq 'Success') {
                [System.Drawing.PointF[]]$points = @(
                    [System.Drawing.PointF]::new([single]($Size * 0.27), [single]($Size * 0.52))
                    [System.Drawing.PointF]::new([single]($Size * 0.43), [single]($Size * 0.68))
                    [System.Drawing.PointF]::new([single]($Size * 0.74), [single]($Size * 0.34))
                )
                $graphics.DrawLines($pen, $points)
            }
            else {
                $graphics.DrawLine($pen, $Size * 0.34, $Size * 0.34, $Size * 0.66, $Size * 0.66)
                $graphics.DrawLine($pen, $Size * 0.66, $Size * 0.34, $Size * 0.34, $Size * 0.66)
            }
            $pen.Dispose()
        }
        else {
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(55, 65, 81), 1.7)
            $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            if ($Kind -eq 'Copy') {
                $graphics.DrawRectangle($pen, $Size * 0.32, $Size * 0.18, $Size * 0.48, $Size * 0.56)
                $graphics.DrawRectangle($pen, $Size * 0.18, $Size * 0.32, $Size * 0.48, $Size * 0.50)
            }
            else {
                $graphics.DrawLine($pen, $Size * 0.50, $Size * 0.15, $Size * 0.50, $Size * 0.62)
                $graphics.DrawLine($pen, $Size * 0.31, $Size * 0.44, $Size * 0.50, $Size * 0.64)
                $graphics.DrawLine($pen, $Size * 0.69, $Size * 0.44, $Size * 0.50, $Size * 0.64)
                $graphics.DrawLine($pen, $Size * 0.23, $Size * 0.79, $Size * 0.77, $Size * 0.79)
            }
            $pen.Dispose()
        }
    }
    finally {
        $graphics.Dispose()
    }
    return $bitmap
}

function Format-CommandArgument {
    param([string]$Value)

    return '"{0}"' -f $Value.Replace('"', '""')
}

function Get-EquivalentCommand {
    param(
        [string]$Source,
        [string]$Destination,
        [bool]$MergeDestination,
        [bool]$overwriteMatchingFiles
    )

    if ($MergeDestination) {
        $Source = "$($Source.TrimEnd('/'))/*"
        $Destination = "$($Destination.TrimEnd('/'))/"
    }
    $noClobberArgument = if ($overwriteMatchingFiles) { '' } else { ' --no-clobber' }
    return 'gcloud storage mv{0} {1} {2}' -f $noClobberArgument, (Format-CommandArgument $Source), (Format-CommandArgument $Destination)
}

function ConvertFrom-GcloudMessage {
    param([psobject]$Record)

    $action = ''
    $sourceObject = ''
    $destinationObject = ''
    $unstructuredMessage = $Record.Message
    if ($Record.Message -match '^\s*(?<Action>Copying|Removing)\s+(?<Source>.+?)(?:\s+to\s+(?<Destination>.+?))?(?:\.\.\.)?\s*$') {
        $action = $Matches.Action
        $sourceObject = $Matches.Source.Trim()
        if ($Matches.ContainsKey('Destination')) {
            $destinationObject = $Matches.Destination.Trim()
        }
        $unstructuredMessage = ''
    }

    return [pscustomobject]@{
        Sequence = $Record.Sequence
        Timestamp = $Record.Timestamp
        Stream = $Record.Stream
        Action = $action
        SourceObject = $sourceObject
        DestinationObject = $destinationObject
        UnstructuredMessage = $unstructuredMessage
        Message = $Record.Message
    }
}

function Get-GcsPath {
    param([System.Windows.Forms.TextBox]$TextBox)

    $path = $TextBox.Text.Trim()
    if ($path.StartsWith('gs://', [System.StringComparison]::OrdinalIgnoreCase)) {
        $path = $path.Substring(5)
    }
    return "gs://$path"
}

function Get-BucketName {
    param([System.Windows.Forms.TextBox]$TextBox)

    $path = $TextBox.Text.Trim()
    if ($path.StartsWith('gs://', [System.StringComparison]::OrdinalIgnoreCase)) {
        $path = $path.Substring(5)
    }
    return ($path -split '/', 2)[0].Trim()
}

function Test-IsUsBucketLocation {
    param([psobject]$Metadata)

    if (-not $Metadata.Known) {
        return $false
    }

    $locations = @(
        @($Metadata.Location, $Metadata.DataLocations) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    if ($locations.Count -eq 0) {
        return $false
    }

    return @($locations | Where-Object { [string]$_ -notmatch '^(?i:US(?:-|$)|NAM4$)' }).Count -eq 0
}

function Update-BucketLocationDisplay {
    $sourceBucket = Get-BucketName $sourceTextBox
    $destinationBucket = Get-BucketName $destinationTextBox

    $neutralColor = [System.Drawing.Color]::FromArgb(75, 85, 99)
    $greenColor = [System.Drawing.Color]::FromArgb(28, 128, 82)
    $yellowColor = [System.Drawing.Color]::FromArgb(166, 112, 0)
    $orangeColor = [System.Drawing.Color]::FromArgb(196, 91, 0)
    $redColor = [System.Drawing.Color]::FromArgb(176, 35, 45)

    foreach ($item in @(
        @{ Bucket = $sourceBucket; LocationLabel = $sourceLocationLabel; StorageLabel = $sourceStorageClassLabel },
        @{ Bucket = $destinationBucket; LocationLabel = $destinationLocationLabel; StorageLabel = $destinationStorageClassLabel }
    )) {
        $item.LocationLabel.ForeColor = $neutralColor
        $item.StorageLabel.ForeColor = $neutralColor
        if ([string]::IsNullOrWhiteSpace($item.Bucket)) {
            $item.LocationLabel.Text = ''
            $item.StorageLabel.Text = ''
        }
        elseif (-not $script:GcloudReady) {
            $item.LocationLabel.Text = 'Location: unknown'
            $item.StorageLabel.Text = 'Default storage class: unknown'
        }
        elseif ($script:BucketLocationCache.ContainsKey($item.Bucket)) {
            $metadata = $script:BucketLocationCache[$item.Bucket]
            $item.LocationLabel.Text = if ($metadata.Known) {
                "Location: $($metadata.DisplayLocation)"
            }
            else {
                'Location: unknown'
            }
            $item.StorageLabel.Text = if ($metadata.StorageClassKnown) {
                "Default storage class: $($metadata.StorageClass)"
            }
            else {
                'Default storage class: unknown'
            }
        }
        else {
            $item.LocationLabel.Text = 'Location: checking...'
            $item.StorageLabel.Text = 'Default storage class: checking...'
        }
    }

    $locationWarningLabel.Text = ''
    $locationWarningLabel.ForeColor = $yellowColor
    if ([string]::IsNullOrWhiteSpace($sourceBucket) -or [string]::IsNullOrWhiteSpace($destinationBucket)) {
        return
    }
    if (-not $script:GcloudReady) {
        $locationWarningLabel.Text = 'Warning: Bucket location and storage class are unknown; costs may apply.'
        return
    }
    if (-not $script:BucketLocationCache.ContainsKey($sourceBucket) -or
        -not $script:BucketLocationCache.ContainsKey($destinationBucket)) {
        return
    }

    $sourceMetadata = $script:BucketLocationCache[$sourceBucket]
    $destinationMetadata = $script:BucketLocationCache[$destinationBucket]

    $locationRisk = 'Unknown'
    $locationReason = 'one or both bucket locations are unknown'
    if ($sourceMetadata.Known -and $destinationMetadata.Known) {
        if ($sourceMetadata.LocationKey -eq $destinationMetadata.LocationKey) {
            $locationRisk = 'Green'
            $sourceLocationLabel.ForeColor = $greenColor
            $destinationLocationLabel.ForeColor = $greenColor
            $locationReason = ''
        }
        elseif ((Test-IsUsBucketLocation $sourceMetadata) -and (Test-IsUsBucketLocation $destinationMetadata)) {
            $locationRisk = 'Yellow'
            $sourceLocationLabel.ForeColor = $yellowColor
            $destinationLocationLabel.ForeColor = $yellowColor
            $locationReason = 'the buckets use different US locations'
        }
        else {
            $locationRisk = 'Red'
            $sourceLocationLabel.ForeColor = $redColor
            $destinationLocationLabel.ForeColor = $redColor
            $locationReason = 'the buckets use different locations and at least one is outside the US'
        }
    }

    $sourceStorageRisk = 'Unknown'
    $sourceStorageReason = 'the source storage class is unknown'
    if ($sourceMetadata.StorageClassKnown) {
        switch ($sourceMetadata.StorageClass.ToUpperInvariant()) {
            'STANDARD' {
                $sourceStorageRisk = 'Green'
                $sourceStorageClassLabel.ForeColor = $greenColor
                $sourceStorageReason = ''
            }
            'NEARLINE' {
                $sourceStorageRisk = 'Yellow'
                $sourceStorageClassLabel.ForeColor = $yellowColor
                $sourceStorageReason = 'the source uses NEARLINE storage'
            }
            'COLDLINE' {
                $sourceStorageRisk = 'Orange'
                $sourceStorageClassLabel.ForeColor = $orangeColor
                $sourceStorageReason = 'the source uses COLDLINE storage'
            }
            { $_ -in @('ARCHIVE', 'ARCHIVAL') } {
                $sourceStorageRisk = 'Red'
                $sourceStorageClassLabel.ForeColor = $redColor
                $sourceStorageReason = 'the source uses ARCHIVE storage'
            }
        }
    }
    if ($destinationMetadata.StorageClassKnown) {
        $destinationStorageClassLabel.ForeColor = $greenColor
    }

    $unknownReasons = @()
    if ($locationRisk -eq 'Unknown') { $unknownReasons += $locationReason }
    if ($sourceStorageRisk -eq 'Unknown') { $unknownReasons += $sourceStorageReason }
    if (-not $destinationMetadata.StorageClassKnown) { $unknownReasons += 'the destination storage class is unknown' }
    $knownCostReasons = @()
    if ($locationRisk -in @('Yellow', 'Red')) { $knownCostReasons += $locationReason }
    if ($sourceStorageRisk -in @('Yellow', 'Orange', 'Red')) { $knownCostReasons += $sourceStorageReason }

    if ($knownCostReasons.Count -eq 0 -and $unknownReasons.Count -eq 0) {
        return
    }

    $reasonText = (@($knownCostReasons + $unknownReasons) -join ', and ')
    $hasRedAlert = $locationRisk -eq 'Red' -or $sourceStorageRisk -eq 'Red'
    if ($hasRedAlert) {
        $locationWarningLabel.ForeColor = $redColor
    }
    if ($knownCostReasons.Count -gt 0 -and $unknownReasons.Count -gt 0) {
        $locationWarningLabel.Text = "$(if ($hasRedAlert) { 'High-cost warning' } else { 'Warning' }): $reasonText; costs will apply and additional costs may apply."
    }
    elseif ($knownCostReasons.Count -gt 0) {
        $locationWarningLabel.Text = "$(if ($hasRedAlert) { 'High-cost warning' } else { 'Warning' }): $reasonText; costs will apply."
    }
    else {
        $locationWarningLabel.Text = "Warning: $reasonText; costs may apply."
    }
}

function Start-NextBucketLocationLookup {
    if ($null -ne $script:MetadataOperation -or -not $script:GcloudReady) {
        return
    }

    $sourceBucket = Get-BucketName $sourceTextBox
    $destinationBucket = Get-BucketName $destinationTextBox
    $bucket = @($sourceBucket, $destinationBucket) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $script:BucketLocationCache.ContainsKey($_) } |
        Select-Object -Unique -First 1
    if ($null -eq $bucket) {
        Update-BucketLocationDisplay
        return
    }

    $script:MetadataBucket = $bucket
    $script:MetadataPowerShell = [PowerShell]::Create()
    [void]$script:MetadataPowerShell.AddScript({
        param($GcloudPath, $Bucket)
        try {
            $json = & $GcloudPath storage buckets describe "gs://$Bucket" --format=json --quiet 2>$null
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($json -join ''))) {
                return [pscustomobject]@{ Known = $false; DisplayLocation = ''; LocationKey = ''; Location = ''; DataLocations = @(); StorageClassKnown = $false; StorageClass = '' }
            }
            $metadata = ($json -join "`n") | ConvertFrom-Json
            $customPlacementProperty = $metadata.PSObject.Properties['custom_placement_config']
            if ($null -eq $customPlacementProperty) {
                $customPlacementProperty = $metadata.PSObject.Properties['customPlacementConfig']
            }
            $customPlacement = if ($null -eq $customPlacementProperty) { $null } else { $customPlacementProperty.Value }
            $dataLocations = @()
            if ($null -ne $customPlacement) {
                $dataLocationsProperty = $customPlacement.PSObject.Properties['data_locations']
                if ($null -eq $dataLocationsProperty) {
                    $dataLocationsProperty = $customPlacement.PSObject.Properties['dataLocations']
                }
                if ($null -ne $dataLocationsProperty) {
                    $dataLocations = @($dataLocationsProperty.Value)
                }
            }
            $displayLocation = if ($dataLocations.Count -gt 0) {
                ($dataLocations | ForEach-Object { [string]$_ }) -join '/'
            }
            else {
                [string]$metadata.location
            }
            $known = -not [string]::IsNullOrWhiteSpace([string]$metadata.location)
            $storageClassProperty = $metadata.PSObject.Properties['default_storage_class']
            if ($null -eq $storageClassProperty) {
                $storageClassProperty = $metadata.PSObject.Properties['defaultStorageClass']
            }
            if ($null -eq $storageClassProperty) {
                $storageClassProperty = $metadata.PSObject.Properties['storage_class']
            }
            $storageClass = if ($null -eq $storageClassProperty) { '' } else { [string]$storageClassProperty.Value }
            return [pscustomobject]@{
                Known = $known
                DisplayLocation = $displayLocation
                LocationKey = "$([string]$metadata.location)|$(($dataLocations | Sort-Object) -join '|')"
                Location = [string]$metadata.location
                DataLocations = $dataLocations
                StorageClassKnown = -not [string]::IsNullOrWhiteSpace($storageClass)
                StorageClass = $storageClass.ToUpperInvariant()
            }
        }
        catch {
            return [pscustomobject]@{ Known = $false; DisplayLocation = ''; LocationKey = ''; Location = ''; DataLocations = @(); StorageClassKnown = $false; StorageClass = '' }
        }
    }).AddArgument($script:GcloudPath).AddArgument($bucket)
    $script:MetadataOperation = $script:MetadataPowerShell.BeginInvoke()
    $metadataOperationTimer.Start()
}

function New-IconButton {
    param(
        [System.Drawing.Image]$Image,
        [string]$AccessibleName,
        [int]$Left,
        [int]$Top
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Left = $Left
    $button.Top = $Top
    $button.Width = 30
    $button.Height = 28
    $button.Anchor = 'Top, Right'
    $button.Image = $Image
    $button.AccessibleName = $AccessibleName
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(209, 213, 219)
    $button.BackColor = [System.Drawing.Color]::White
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $button
}

function New-StatusIndicator {
    param(
        [string]$Name,
        [int]$Right
    )

    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $false
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $textWidth = [System.Windows.Forms.TextRenderer]::MeasureText($Name, $label.Font).Width
    $label.Width = $textWidth + 25
    $label.Height = 22
    $label.Left = $Right - $label.Width
    $label.Top = 18
    $label.Anchor = 'Top, Right'
    $label.Text = $Name
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $label.ImageAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $label.Image = $failureIcon
    $label.ForeColor = [System.Drawing.Color]::FromArgb(75, 85, 99)
    return $label
}

function Set-StatusIndicator {
    param(
        [System.Windows.Forms.Label]$Indicator,
        [bool]$Ready,
        [string]$Name,
        [string]$FailureHelp
    )

    $Indicator.Text = $Name
    if ($Ready) {
        $Indicator.Image = $successIcon
        $toolTip.SetToolTip($Indicator, '')
    }
    else {
        $Indicator.Image = $failureIcon
        $toolTip.SetToolTip($Indicator, $FailureHelp)
    }
}

function Test-GcloudAvailable {
    $command = Get-Command gcloud -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        $script:GcloudPath = $null
        return $false
    }

    $script:GcloudPath = $command.Source
    return $true
}

function Test-GcloudAuth {
    if (-not $script:GcloudReady) {
        return $false
    }

    try {
        $output = & $script:GcloudPath auth print-access-token --quiet 2>$null
        return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($output -join '')))
    }
    catch {
        return $false
    }
}

function Update-Prerequisites {
    if (-not $script:GcloudReady) {
        $script:GcloudReady = Test-GcloudAvailable
        Set-StatusIndicator $gcloudStatus $script:GcloudReady 'gcloud on PATH' 'Install the Google Cloud CLI, then add its bin folder to PATH and restart this application.'
    }

    if (-not $script:AuthReady) {
        $script:AuthReady = Test-GcloudAuth
        Set-StatusIndicator $authStatus $script:AuthReady 'gcloud Auth' 'Open a terminal, run gcloud auth login, and then return to this application.'
    }

    Update-ExecuteState
    Update-BucketLocationDisplay
    Start-NextBucketLocationLookup
    if ($script:GcloudReady -and $script:AuthReady) {
        $prerequisiteTimer.Stop()
    }
}

function Update-ExecuteState {
    $pathsPresent = -not [string]::IsNullOrWhiteSpace($sourceTextBox.Text) -and
        -not [string]::IsNullOrWhiteSpace($destinationTextBox.Text)
    $executeButton.Enabled = $pathsPresent -and $script:GcloudReady -and $script:AuthReady -and $null -eq $script:Operation
}

function Update-CommandPreview {
    $previewTimer.Stop()
    Update-ExecuteState

    if ([string]::IsNullOrWhiteSpace($sourceTextBox.Text) -or
        [string]::IsNullOrWhiteSpace($destinationTextBox.Text)) {
        $commandTextBox.Text = ''
        return
    }

    $commandTextBox.Text = Get-EquivalentCommand `
        (Get-GcsPath $sourceTextBox) `
        (Get-GcsPath $destinationTextBox) `
        $mergeDestinationCheckBox.Checked `
        $overwriteMatchingFilesCheckBox.Checked
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'GCS Move / Rename'
$form.ClientSize = New-Object System.Drawing.Size(760, 730)
$form.MinimumSize = New-Object System.Drawing.Size(650, 670)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(247, 248, 250)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 12000
$toolTip.InitialDelay = 300
$toolTip.ReshowDelay = 100

$successIcon = New-IconBitmap Success
$failureIcon = New-IconBitmap Failure
$copyIcon = New-IconBitmap Copy 18
$downloadIcon = New-IconBitmap Download 18

$gcloudStatus = New-StatusIndicator 'gcloud on PATH' 616
$authStatus = New-StatusIndicator 'gcloud Auth' 736
$form.Controls.AddRange(@($gcloudStatus, $authStatus))

$sourceLabel = New-Object System.Windows.Forms.Label
$sourceLabel.Text = 'Source Google Cloud Storage Bucket path'
$sourceLabel.Left = 24
$sourceLabel.Top = 70
$sourceLabel.AutoSize = $true

$sourceTextBox = New-Object System.Windows.Forms.TextBox
$sourcePrefixLabel = New-Object System.Windows.Forms.Label
$sourcePrefixLabel.Text = 'gs://'
$sourcePrefixLabel.Left = 24
$sourcePrefixLabel.Top = 95
$sourcePrefixLabel.AutoSize = $true
$sourcePrefixLabel.Font = New-Object System.Drawing.Font('Consolas', 10)

$sourceTextBox.Left = 66
$sourceTextBox.Top = 92
$sourceTextBox.Width = 668
$sourceTextBox.Anchor = 'Top, Left, Right'
$sourceTextBox.Font = New-Object System.Drawing.Font('Consolas', 10)

$sourceLocationLabel = New-Object System.Windows.Forms.Label
$sourceLocationLabel.Text = ''
$sourceLocationLabel.Left = 66
$sourceLocationLabel.Top = 120
$sourceLocationLabel.Width = 250
$sourceLocationLabel.ForeColor = [System.Drawing.Color]::FromArgb(75, 85, 99)

$sourceStorageClassLabel = New-Object System.Windows.Forms.Label
$sourceStorageClassLabel.Text = ''
$sourceStorageClassLabel.Left = 330
$sourceStorageClassLabel.Top = 120
$sourceStorageClassLabel.AutoSize = $true
$sourceStorageClassLabel.ForeColor = [System.Drawing.Color]::FromArgb(75, 85, 99)

$destinationLabel = New-Object System.Windows.Forms.Label
$destinationLabel.Text = 'Destination Google Cloud Storage Bucket path'
$destinationLabel.Left = 24
$destinationLabel.Top = 150
$destinationLabel.AutoSize = $true

$destinationTextBox = New-Object System.Windows.Forms.TextBox
$destinationPrefixLabel = New-Object System.Windows.Forms.Label
$destinationPrefixLabel.Text = 'gs://'
$destinationPrefixLabel.Left = 24
$destinationPrefixLabel.Top = 175
$destinationPrefixLabel.AutoSize = $true
$destinationPrefixLabel.Font = New-Object System.Drawing.Font('Consolas', 10)

$destinationTextBox.Left = 66
$destinationTextBox.Top = 172
$destinationTextBox.Width = 668
$destinationTextBox.Anchor = 'Top, Left, Right'
$destinationTextBox.Font = New-Object System.Drawing.Font('Consolas', 10)

$destinationLocationLabel = New-Object System.Windows.Forms.Label
$destinationLocationLabel.Text = ''
$destinationLocationLabel.Left = 66
$destinationLocationLabel.Top = 200
$destinationLocationLabel.Width = 250
$destinationLocationLabel.ForeColor = [System.Drawing.Color]::FromArgb(75, 85, 99)

$destinationStorageClassLabel = New-Object System.Windows.Forms.Label
$destinationStorageClassLabel.Text = ''
$destinationStorageClassLabel.Left = 330
$destinationStorageClassLabel.Top = 200
$destinationStorageClassLabel.AutoSize = $true
$destinationStorageClassLabel.ForeColor = [System.Drawing.Color]::FromArgb(75, 85, 99)

$locationWarningLabel = New-Object System.Windows.Forms.Label
$locationWarningLabel.Text = ''
$locationWarningLabel.Left = 24
$locationWarningLabel.Top = 224
$locationWarningLabel.AutoSize = $true
$locationWarningLabel.MaximumSize = New-Object System.Drawing.Size(710, 0)
$locationWarningLabel.ForeColor = [System.Drawing.Color]::FromArgb(176, 35, 45)
$locationWarningLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$mergeDestinationCheckBox = New-Object System.Windows.Forms.CheckBox
$mergeDestinationCheckBox.Text = 'Merge into destination directory'
$mergeDestinationCheckBox.Left = 24
$mergeDestinationCheckBox.Top = 267
$mergeDestinationCheckBox.AutoSize = $true
$mergeDestinationCheckBox.Checked = $true
$toolTip.SetToolTip($mergeDestinationCheckBox, 'Move the source directory contents directly into the destination instead of creating a source-named subdirectory.')

$overwriteMatchingFilesCheckBox = New-Object System.Windows.Forms.CheckBox
$overwriteMatchingFilesCheckBox.Text = 'Overwrite matching files'
$overwriteMatchingFilesCheckBox.Left = 280
$overwriteMatchingFilesCheckBox.Top = 267
$overwriteMatchingFilesCheckBox.AutoSize = $true
$overwriteMatchingFilesCheckBox.Checked = $false
$toolTip.SetToolTip($overwriteMatchingFilesCheckBox, 'Allow matching destination files to be replaced; when unchecked, gcloud uses --no-clobber and skips them.')

$executeButton = New-Object System.Windows.Forms.Button
$executeButton.Text = 'Execute'
$executeButton.Left = 634
$executeButton.Top = 260
$executeButton.Width = 100
$executeButton.Height = 32
$executeButton.Anchor = 'Top, Right'
$executeButton.Enabled = $false
$executeButton.BackColor = [System.Drawing.Color]::FromArgb(31, 92, 162)
$executeButton.ForeColor = [System.Drawing.Color]::White
$executeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

$commandLabel = New-Object System.Windows.Forms.Label
$commandLabel.Text = 'Equivalent gcloud command'
$commandLabel.Left = 24
$commandLabel.Top = 312
$commandLabel.AutoSize = $true

$copyCommandButton = New-IconButton $copyIcon 'Copy equivalent command' 704 304
$toolTip.SetToolTip($copyCommandButton, 'Copy equivalent gcloud command')

$commandTextBox = New-Object System.Windows.Forms.TextBox
$commandTextBox.Left = 24
$commandTextBox.Top = 340
$commandTextBox.Width = 710
$commandTextBox.Height = 70
$commandTextBox.Anchor = 'Top, Left, Right'
$commandTextBox.Multiline = $true
$commandTextBox.ReadOnly = $true
$commandTextBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$commandTextBox.WordWrap = $false
$commandTextBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$commandTextBox.BackColor = [System.Drawing.Color]::White

$outputLabel = New-Object System.Windows.Forms.Label
$outputLabel.Text = 'Output'
$outputLabel.Left = 24
$outputLabel.Top = 430
$outputLabel.AutoSize = $true

$downloadOutputButton = New-IconButton $downloadIcon 'Download output as CSV' 668 422
$toolTip.SetToolTip($downloadOutputButton, 'Download structured output as CSV')
$downloadOutputButton.Enabled = $false

$copyOutputButton = New-IconButton $copyIcon 'Copy output' 704 422
$toolTip.SetToolTip($copyOutputButton, 'Copy output')

$outputTextBox = New-Object System.Windows.Forms.TextBox
$outputTextBox.Left = 24
$outputTextBox.Top = 458
$outputTextBox.Width = 710
$outputTextBox.Height = 246
$outputTextBox.Anchor = 'Top, Bottom, Left, Right'
$outputTextBox.Multiline = $true
$outputTextBox.ReadOnly = $true
$outputTextBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$outputTextBox.WordWrap = $false
$outputTextBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$outputTextBox.BackColor = [System.Drawing.Color]::White
$outputTextBox.Text = 'Checking prerequisites...'

$form.Controls.AddRange(@(
    $sourceLabel,
    $sourcePrefixLabel,
    $sourceTextBox,
    $sourceLocationLabel,
    $sourceStorageClassLabel,
    $destinationLabel,
    $destinationPrefixLabel,
    $destinationTextBox,
    $destinationLocationLabel,
    $destinationStorageClassLabel,
    $locationWarningLabel,
    $mergeDestinationCheckBox,
    $overwriteMatchingFilesCheckBox,
    $executeButton,
    $commandLabel,
    $copyCommandButton,
    $commandTextBox,
    $outputLabel,
    $downloadOutputButton,
    $copyOutputButton,
    $outputTextBox
))

$previewTimer = New-Object System.Windows.Forms.Timer
$previewTimer.Interval = 700
$previewTimer.Add_Tick({ Update-CommandPreview })

$metadataDebounceTimer = New-Object System.Windows.Forms.Timer
$metadataDebounceTimer.Interval = 1200
$metadataDebounceTimer.Add_Tick({
    $metadataDebounceTimer.Stop()
    Update-BucketLocationDisplay
    Start-NextBucketLocationLookup
})

$metadataOperationTimer = New-Object System.Windows.Forms.Timer
$metadataOperationTimer.Interval = 200
$metadataOperationTimer.Add_Tick({
    if ($null -eq $script:MetadataOperation -or -not $script:MetadataOperation.IsCompleted) {
        return
    }

    $metadataOperationTimer.Stop()
    try {
        $result = @($script:MetadataPowerShell.EndInvoke($script:MetadataOperation)) | Select-Object -Last 1
        if ($null -eq $result) {
            $result = [pscustomobject]@{ Known = $false; DisplayLocation = ''; LocationKey = ''; Location = ''; DataLocations = @(); StorageClassKnown = $false; StorageClass = '' }
        }
        $script:BucketLocationCache[$script:MetadataBucket] = $result
    }
    catch {
        $script:BucketLocationCache[$script:MetadataBucket] = [pscustomobject]@{
            Known = $false
            DisplayLocation = ''
            LocationKey = ''
            Location = ''
            DataLocations = @()
            StorageClassKnown = $false
            StorageClass = ''
        }
    }
    finally {
        $script:MetadataPowerShell.Dispose()
        $script:MetadataPowerShell = $null
        $script:MetadataOperation = $null
        $script:MetadataBucket = $null
    }

    Update-BucketLocationDisplay
    Start-NextBucketLocationLookup
})

$prerequisiteTimer = New-Object System.Windows.Forms.Timer
$prerequisiteTimer.Interval = 10000
$prerequisiteTimer.Add_Tick({ Update-Prerequisites })

$operationTimer = New-Object System.Windows.Forms.Timer
$operationTimer.Interval = 200
$operationTimer.Add_Tick({
    if ($null -eq $script:Operation -or -not $script:Operation.IsCompleted) {
        return
    }

    $operationTimer.Stop()
    try {
        $result = $script:OperationPowerShell.EndInvoke($script:Operation)
        $script:StructuredOutput = @($result | ForEach-Object { ConvertFrom-GcloudMessage $_ })
        $combinedOutput = ($script:StructuredOutput | ForEach-Object { $_.Message }) -join "`r`n"
        if ([string]::IsNullOrWhiteSpace($combinedOutput)) {
            $combinedOutput = 'Command completed without output.'
        }
        $outputTextBox.Text = $combinedOutput
        $downloadOutputButton.Enabled = $script:StructuredOutput.Count -gt 0
    }
    catch {
        $outputTextBox.Text = "Command failed:`r`n$($_.Exception.Message)"
        $script:StructuredOutput = @([pscustomobject]@{
            Sequence = 1
            Timestamp = [DateTime]::UtcNow.ToString('o')
            Stream = 'stderr'
            Action = ''
            SourceObject = ''
            DestinationObject = ''
            UnstructuredMessage = $_.Exception.Message
            Message = $_.Exception.Message
        })
        $downloadOutputButton.Enabled = $true
    }
    finally {
        $script:OperationPowerShell.Dispose()
        $script:OperationPowerShell = $null
        $script:Operation = $null
        $sourceTextBox.Enabled = $true
        $destinationTextBox.Enabled = $true
        $mergeDestinationCheckBox.Enabled = $true
        $overwriteMatchingFilesCheckBox.Enabled = $true
        Update-ExecuteState
    }
})

$pathChanged = {
    param($sender, $eventArgs)
    if ($sender.Text.StartsWith('gs://', [System.StringComparison]::OrdinalIgnoreCase)) {
        $sender.Text = $sender.Text.Substring(5)
        $sender.SelectionStart = $sender.Text.Length
    }
    $previewTimer.Stop()
    $previewTimer.Start()
    $metadataDebounceTimer.Stop()
    $metadataDebounceTimer.Start()
    Update-BucketLocationDisplay
    Update-ExecuteState
}
$sourceTextBox.Add_TextChanged($pathChanged)
$destinationTextBox.Add_TextChanged($pathChanged)
$mergeDestinationCheckBox.Add_CheckedChanged({
    $previewTimer.Stop()
    $previewTimer.Start()
})
$overwriteMatchingFilesCheckBox.Add_CheckedChanged({
    $previewTimer.Stop()
    $previewTimer.Start()
})

$copyCommandButton.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($commandTextBox.Text)) {
        [System.Windows.Forms.Clipboard]::SetText($commandTextBox.Text)
    }
})

$copyOutputButton.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($outputTextBox.Text)) {
        [System.Windows.Forms.Clipboard]::SetText($outputTextBox.Text)
    }
})

$downloadOutputButton.Add_Click({
    if ($script:StructuredOutput.Count -eq 0) {
        return
    }

    $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveDialog.Title = 'Save structured output'
    $saveDialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $saveDialog.DefaultExt = 'csv'
    $saveDialog.AddExtension = $true
    $saveDialog.FileName = "gcs-move-output-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss')).csv"
    if ($saveDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:StructuredOutput |
            Select-Object Sequence, Timestamp, Stream, Action, SourceObject, DestinationObject, UnstructuredMessage |
            Export-Csv -Path $saveDialog.FileName -NoTypeInformation -Encoding UTF8
    }
    $saveDialog.Dispose()
})

$executeButton.Add_Click({
    $source = Get-GcsPath $sourceTextBox
    $destination = Get-GcsPath $destinationTextBox
    if ($mergeDestinationCheckBox.Checked) {
        $source = "$($source.TrimEnd('/'))/*"
        $destination = "$($destination.TrimEnd('/'))/"
    }

    $previewTimer.Stop()
    $sourceTextBox.Enabled = $false
    $destinationTextBox.Enabled = $false
    $mergeDestinationCheckBox.Enabled = $false
    $overwriteMatchingFilesCheckBox.Enabled = $false
    $executeButton.Enabled = $false
    $script:StructuredOutput = @()
    $downloadOutputButton.Enabled = $false
    $outputTextBox.Text = 'Waiting for gcloud...'

    $script:OperationPowerShell = [PowerShell]::Create()
    [void]$script:OperationPowerShell.AddScript({
        param($GcloudPath, $Source, $Destination, $overwriteMatchingFiles)
        $sequence = 0
        $arguments = @('storage', 'mv')
        if (-not $overwriteMatchingFiles) {
            $arguments += '--no-clobber'
        }
        $arguments += @('--', $Source, $Destination)
        & $GcloudPath @arguments 2>&1 | ForEach-Object {
            $sequence++
            [pscustomobject]@{
                Sequence = $sequence
                Timestamp = [DateTime]::UtcNow.ToString('o')
                Stream = if ($_ -is [System.Management.Automation.ErrorRecord]) { 'stderr' } else { 'stdout' }
                Message = $_.ToString()
            }
        }
        if ($LASTEXITCODE -ne 0) {
            $sequence++
            [pscustomobject]@{
                Sequence = $sequence
                Timestamp = [DateTime]::UtcNow.ToString('o')
                Stream = 'stderr'
                Message = "gcloud exited with code $LASTEXITCODE."
            }
        }
    }).AddArgument($script:GcloudPath).AddArgument($source).AddArgument($destination).AddArgument($overwriteMatchingFilesCheckBox.Checked)
    $script:Operation = $script:OperationPowerShell.BeginInvoke()
    $operationTimer.Start()
})

$form.Add_Shown({
    $form.Activate()
    Update-Prerequisites
    if (-not ($script:GcloudReady -and $script:AuthReady)) {
        $prerequisiteTimer.Start()
    }
    Update-CommandPreview
})

$form.Add_FormClosed({
    $previewTimer.Stop()
    $metadataDebounceTimer.Stop()
    $metadataOperationTimer.Stop()
    $prerequisiteTimer.Stop()
    $operationTimer.Stop()
    if ($null -ne $script:OperationPowerShell) {
        $script:OperationPowerShell.Stop()
        $script:OperationPowerShell.Dispose()
    }
    if ($null -ne $script:MetadataPowerShell) {
        $script:MetadataPowerShell.Stop()
        $script:MetadataPowerShell.Dispose()
    }
    @($successIcon, $failureIcon, $copyIcon, $downloadIcon) | ForEach-Object { $_.Dispose() }
})

[void]$form.ShowDialog()