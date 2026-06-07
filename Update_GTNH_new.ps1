# Define the path to the 7-Zip executable, if not present, will use the slower built-in Expand-Archive method.
$SevenZipPath = "C:\Program Files\7-Zip\7z.exe"

# If true, temp zip/extract files will not be deleted and will be reused if present.
$ReuseTempFiles = $true

##### SERVER UPDATE SETTINGS #####
# Define folders to overwrite
$ServerFolderNamesToOverwrite = @("mods", "config", "libraries")
# Define files to skip
$ServerFilesToSkip = @("server.properties", "eula.txt", "banned-ips.json", "banned-players.json", "ops.json", "usercache.json", "whitelist.json", "pollution.cfg")
# Define the base URL for the server pack
$ServerBaseUrl = "https://downloads.gtnewhorizons.com/ServerPacks/"
# Define path to server. If empty, the script will skip the server update.
$MinecraftServerPath = "C:\Users\Henrik\Desktop\mc\ServerFiles\GTNewHorizon"

##### CLIENT UPDATE SETTINGS #####
# Define folders to overwrite
$ClientFolderNamesToOverwrite = @("config", "serverutilities", "mods", "libraries", "patches")
# Define files to skip
$ClientFilesToSkip = @("options.txt", "optionsof.txt")
# Define the base URL for the client pack
$ClientBaseUrl = "https://downloads.gtnewhorizons.com/Multi_mc_downloads/"
# Define path to client
# For a MultiMC Installation (or prism), put the base folder of the instance here, not the .minecraft folder. If empty, the script will skip the client update.
$MinecraftClientPath = "C:\Users\Henrik\AppData\Roaming\PrismLauncher\instances\GT_New_Horizons_2.7.0-beta-4_Java_17-21"

function Get-FileFromWeb
{
    param (
        [Parameter(Mandatory)]
        [string]$URL,

        [Parameter(Mandatory)]
        [string]$File
    )
    Begin {
        function Show-Progress
        {
            param (
            # Enter total value
                [Parameter(Mandatory)]
                [Single]$TotalValue,

            # Enter current value
                [Parameter(Mandatory)]
                [Single]$CurrentValue,

            # Enter custom progresstext
                [Parameter(Mandatory)]
                [string]$ProgressText,

            # Enter value suffix
                [Parameter()]
                [string]$ValueSuffix,

            # Enter bar lengh suffix
                [Parameter()]
                [int]$BarSize = 40,

            # show complete bar
                [Parameter()]
                [switch]$Complete
            )

            # calc %
            $percent = $CurrentValue / $TotalValue
            $percentComplete = $percent * 100
            if ($ValueSuffix)
            {
                $ValueSuffix = " $ValueSuffix" # add space in front
            }
            if ($psISE)
            {
                Write-Progress "$ProgressText $CurrentValue$ValueSuffix of $TotalValue$ValueSuffix" -id 0 -percentComplete $percentComplete
            }
            else
            {
                # build progressbar with string function
                $curBarSize = $BarSize * $percent
                $progbar = ""
                $progbar = $progbar.PadRight($curBarSize, [char]9608)
                $progbar = $progbar.PadRight($BarSize, [char]9617)

                if (!$Complete.IsPresent)
                {
                    Write-Host -NoNewLine "`r$ProgressText $progbar [ $($CurrentValue.ToString("#.###").PadLeft($TotalValue.ToString("#.###").Length) )$ValueSuffix / $($TotalValue.ToString("#.###") )$ValueSuffix ] $($percentComplete.ToString("##0.00").PadLeft(6) ) % complete"
                }
                else
                {
                    Write-Host -NoNewLine "`r$ProgressText $progbar [ $($TotalValue.ToString("#.###").PadLeft($TotalValue.ToString("#.###").Length) )$ValueSuffix / $($TotalValue.ToString("#.###") )$ValueSuffix ] $($percentComplete.ToString("##0.00").PadLeft(6) ) % complete"
                }
            }
        }
    }
    Process {

        Write-Host "Downloading $URL to $File"
        try
        {
            $storeEAP = $ErrorActionPreference
            $ErrorActionPreference = 'Stop'

            # invoke request
            $request = [System.Net.HttpWebRequest]::Create($URL)
            $response = $request.GetResponse()

            if ($response.StatusCode -eq 401 -or $response.StatusCode -eq 403 -or $response.StatusCode -eq 404)
            {
                throw "Remote file either doesn't exist, is unauthorized, or is forbidden for '$URL'."
            }

            if ($File -match '^\.\\')
            {
                $File = Join-Path (Get-Location -PSProvider "FileSystem") ($File -Split '^\.')[1]
            }

            if ($File -and !(Split-Path $File))
            {
                $File = Join-Path (Get-Location -PSProvider "FileSystem") $File
            }

            if ($File)
            {
                $fileDirectory = $([System.IO.Path]::GetDirectoryName($File) )
                if (!(Test-Path ($fileDirectory)))
                {
                    [System.IO.Directory]::CreateDirectory($fileDirectory) | Out-Null
                }
            }

            [long]$fullSize = $response.ContentLength
            $fullSizeMB = $fullSize / 1024 / 1024

            # define buffer
            [byte[]]$buffer = new-object byte[] 1048576
            [long]$total = [long]$count = 0

            # create reader / writer
            $reader = $response.GetResponseStream()
            $writer = new-object System.IO.FileStream $File, "Create"

            # start download
            $finalBarCount = 0 #show final bar only one time
            do
            {

                $count = $reader.Read($buffer, 0, $buffer.Length)

                $writer.Write($buffer, 0, $count)

                $total += $count
                $totalMB = $total / 1024 / 1024

                if ($fullSize -gt 0)
                {
                    Show-Progress -TotalValue $fullSizeMB -CurrentValue $totalMB -ProgressText "Downloading $( $File.Name )" -ValueSuffix "MB"
                }

                if ($total -eq $fullSize -and $count -eq 0 -and $finalBarCount -eq 0)
                {
                    Show-Progress -TotalValue $fullSizeMB -CurrentValue $totalMB -ProgressText "Downloading $( $File.Name )" -ValueSuffix "MB" -Complete
                    $finalBarCount++
                    #Write-Host "$finalBarCount"
                }

            } while ($count -gt 0)
        }

        catch
        {

            $ExeptionMsg = $_.Exception.Message
            Write-Host "Download breaks with error : $ExeptionMsg"
        }

        finally
        {
            # cleanup
            if ($reader)
            {
                $reader.Close()
            }
            if ($writer)
            {
                $writer.Flush();$writer.Close()
            }

            $ErrorActionPreference = $storeEAP
            [GC]::Collect()
            Write-Host ""
        }
    }
}

function Expand-Archive-Fast
{
    param (
        [Parameter(Mandatory)]
        [string]$ArchivePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    # 7-Zip is not installed use the built-in Expand-Archive
    if (-Not (Test-Path $SevenZipPath))
    {
        Expand-Archive -Path $ArchivePath -DestinationPath $DestinationPath -Force
        return
    }
    else
    {
        $Arguments = "x -y -o$DestinationPath $ArchivePath"
        Start-Process -FilePath $SevenZipPath -ArgumentList $Arguments -Wait
    }
}

function Update-Minecraft
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$MinecraftPath,
        [Parameter(Mandatory = $true)]
        [string]$Version,
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [Array]$FoldersToOverwrite,
        [Parameter(Mandatory = $false)]
        [Array]$FilesToSkip,
        [Parameter(Mandatory = $true)]
        [Boolean]$IsClient,
        [Parameter(Mandatory = $false)]
        [string]$ExtracedFolder
    )

    # Decide if server or client for unique temp names
    $TypeString = if ($IsClient)
    {
        "Client"
    }
    else
    {
        "Server"
    }

    if (-Not $PSBoundParameters.ContainsKey('ExtracedFolder'))
    {
        if ($Version -match 'Java_17')
        {
            $VersionString = $Version
        }
        else
        {
            if ($IsClient)
            {
                $VersionString = "${Version}_Java_17-25"
            }
            else
            {
                $VersionString = "${Version}_Server_Java_17-25"
            }
        }

        if ($VersionString -match "beta")
        {
            $DownloadURL = "${BaseUrl}betas/GT_New_Horizons_${VersionString}.zip"
        }
        else
        {
            $DownloadURL = "${BaseUrl}GT_New_Horizons_${VersionString}.zip"
        }

        $TempZipPath = "$env:TEMP\GTNH_${TypeString}_${VersionString}.zip"
        $TempExtractPath = "$env:TEMP\GTNH_${TypeString}_${VersionString}_Extracted"

        # Download the pack if not already present
        if (-not (Test-Path $TempZipPath) -or -not $ReuseTempFiles)
        {
            Write-Host "Downloading GTNH pack from $DownloadURL..." -ForegroundColor Yellow
            Get-FileFromWeb -URL $DownloadURL -File $TempZipPath
        }
        else
        {
            Write-Host "Reusing existing downloaded pack at $TempZipPath" -ForegroundColor Yellow
        }

        if (-Not (Test-Path $TempZipPath))
        {
            throw "Failed to download the pack from $DownloadURL. Please check the version and URL."
        }

        # Extract the zip if not already present
        if (-not (Test-Path $TempExtractPath) -or -not $ReuseTempFiles)
        {
            if (Test-Path $TempExtractPath)
            {
                Remove-Item -Recurse -Force $TempExtractPath
            }
            Write-Host "Extracting pack to $TempExtractPath..." -ForegroundColor Yellow
            Expand-Archive-Fast -ArchivePath $TempZipPath -DestinationPath $TempExtractPath
        }
        else
        {
            Write-Host "Reusing existing extracted pack at $TempExtractPath" -ForegroundColor Yellow
        }

        if (-Not (Test-Path $TempExtractPath))
        {
            throw "Failed to extract the pack. Please check the downloaded zip at $TempZipPath."
        }
    }
    else
    {
        Write-Host "Using extracted folder $ExtracedFolder" -ForegroundColor Yellow
        $TempExtractPath = $ExtracedFolder
    }

    # collect folders to overwrite
    $FoundFoldersToOverwrite = @()
    $NormalizedExtractRoot = Join-Path -Path $TempExtractPath.TrimEnd('\', '/') -ChildPath "GT New Horizon $Version"

    foreach ($FolderName in $FoldersToOverwrite)
    {
        Write-Host "Searching for '$FolderName' directories in the extracted files..." -ForegroundColor Yellow
        $SourceCandidates = Get-ChildItem -Path $TempExtractPath -Recurse -Directory | Where-Object { $_.Name -eq $FolderName }

        if ($SourceCandidates.Count -eq 0)
        {
            throw "Could not find a '$FolderName' folder in the extracted files. Please check the server pack at $TempExtractPath"
        }

        $SelectedSource = $null
        $SelectedDestination = $null

        foreach ($src in $SourceCandidates)
        {
            $relative = $src.FullName.Substring($NormalizedExtractRoot.Length + 2).TrimStart('\', '/')
            $candidateDest = Join-Path -Path $MinecraftPath -ChildPath $relative

            if (Test-Path $candidateDest -PathType Container)
            {
                $SelectedSource = $src.FullName
                $SelectedDestination = $candidateDest
                Write-Host "Selected source: $SelectedSource -> existing destination: $SelectedDestination" -ForegroundColor Green
                break
            }
        }

        if (-not $SelectedSource)
        {
            $SelectedSource = $SourceCandidates[0].FullName
            $relative = $SelectedSource.Substring($NormalizedExtractRoot.Length).TrimStart('\', '/')
            $SelectedDestination = Join-Path -Path $MinecraftPath -ChildPath $relative
            Write-Host "No destination existed; mapping source relative path to destination: $SelectedDestination (will be created if missing)." -ForegroundColor Yellow
            if (-not (Test-Path $SelectedDestination))
            {
                New-Item -ItemType Directory -Path $SelectedDestination -Force | Out-Null
            }

        }

        $FoundFoldersToOverwrite += [PSCustomObject]@{
            Folder = $FolderName
            SourceFolder = $SelectedSource
            DestinationFolder = $SelectedDestination
        }
    }

    # collect root files
    $FoundFilesToAdd = @()
    $FoundFilesToOverwrite = @()
    $FilesInRoot = Get-ChildItem -Path $TempExtractPath -File

    foreach ($File in $FilesInRoot)
    {
        $DestinationFile = Join-Path -Path $MinecraftPath -ChildPath $File.Name
        $SourceFile = $File.FullName
        $base = $File.Name.ToLower()

        if ($FilesToSkip -contains $base)
        {
            if (Test-Path $DestinationFile)
            {
                Write-Host "Skipping overwrite (preserving existing): $DestinationFile" -ForegroundColor Yellow
                continue
            }
            else
            {
                Write-Host "File in skip list but missing at destination → will be added: $DestinationFile" -ForegroundColor Yellow
                $FoundFilesToAdd += [PSCustomObject]@{ File = $File.Name; SourceFile = $SourceFile; DestinationFile = $DestinationFile }
            }
        }
        else
        {
            if (-Not (Test-Path $DestinationFile))
            {
                $FoundFilesToAdd += [PSCustomObject]@{ File = $File.Name; SourceFile = $SourceFile; DestinationFile = $DestinationFile }
            }
            else
            {
                $FoundFilesToOverwrite += [PSCustomObject]@{ File = $File.Name; SourceFile = $SourceFile; DestinationFile = $DestinationFile }
            }
        }
    }

    if ($IsClient)
    {
        # We also need to copy the lang files in the .minecraft folder. Find it
        $MFolder = (Get-ChildItem -Path $TempExtractPath -Recurse -Directory | Where-Object { $_.Name -eq ".minecraft" }).FullName
        $DFolder = (Get-ChildItem -Path $MinecraftPath -Recurse -Directory | Where-Object { $_.Name -eq ".minecraft" }).FullName
        $MFolderChildren = Get-ChildItem -Path $MFolder -File
        foreach ($File in $MFolderChildren)
        {
            $SourceFile = Join-Path -Path $MFolder -ChildPath $File.Name
            $DestinationFile = Join-Path -Path $DFolder -ChildPath $File.Name
            $FoundFilesToOverwrite += [PSCustomObject]@{ File = $File.Name; SourceFile = $SourceFile; DestinationFile = $DestinationFile }
        }
    }

    # Confirm the overwrite operation
    Write-Host "The following folders will be overwritten:" -ForegroundColor Yellow
    $FoundFoldersToOverwrite | Format-Table -AutoSize | Out-Host
    Write-Host "The following files will be overwritten:" -ForegroundColor Yellow
    $FoundFilesToOverwrite | Format-Table -AutoSize | Out-Host
    Write-Host "The following files will be added:" -ForegroundColor Yellow
    $FoundFilesToAdd | Format-Table -AutoSize | Out-Host

    #    $choices = '&Yes', '&No'
    #    $Confirm = $Host.UI.PromptForChoice("Confirm Override", "Do you want to proceed with the overwrite operation?", $choices, 1)
    #    if ($Confirm -eq 0)
    if (1 -eq 1)
    {
        function Copy-FolderReplaceWithSkips
        {
            param(
                [Parameter(Mandatory = $true)][string]$SourceRoot,
                [Parameter(Mandatory = $true)][string]$DestRoot,
                [string[]]$SkipNames
            )

            $srcRootNorm = $SourceRoot.TrimEnd('\', '/')
            $destRootNorm = $DestRoot.TrimEnd('\', '/')

            Write-Host "Updating $DestRoot from $SourceRoot" -ForegroundColor Yellow

            if (-not (Test-Path $DestRoot))
            {
                New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null
            }

            # prepare skip set (lowercase) for case-insensitive match
            $skipSet = @()
            if ($SkipNames)
            {
                $skipSet = $SkipNames | ForEach-Object { $_.ToLower() }
            }

            # gather source files and build set of relative paths
            $sourceFiles = Get-ChildItem -Path $SourceRoot -File -Recurse
            $sourceRelSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($sf in $sourceFiles)
            {
                $rel = $sf.FullName.Substring($srcRootNorm.Length).TrimStart('\', '/')
                $sourceRelSet.Add($rel) | Out-Null
            }

            # copy source files to destination respecting skip semantics
            foreach ($sf in $sourceFiles)
            {
                $base = $sf.Name.ToLower()
                $rel = $sf.FullName.Substring($srcRootNorm.Length).TrimStart('\', '/')
                $destFile = Join-Path -Path $destRootNorm -ChildPath $rel
                $destDir = Split-Path -Path $destFile -Parent


                if (-not (Test-Path -LiteralPath $destDir))
                {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                }

                if ($skipSet -contains $base)
                {
                    if (Test-Path $destFile)
                    {
                        Write-Host "Skipping overwrite (preserving existing): $destFile" -ForegroundColor Yellow
                        continue
                    }
                    else
                    {
                        Write-Host "File in skip list not found at destination → copying new: $destFile" -ForegroundColor Yellow
                        Copy-Item -LiteralPath $sf.FullName -Destination $destFile -Force
                    }
                }
                else
                {
                    Write-Host "Writing $destFile"
                    Copy-Item -LiteralPath $sf.FullName -Destination $destFile -Force
                }
            }

            # remove files in destination that are not present in source and not in skipSet
            $destFiles = Get-ChildItem $DestRoot -File -Recurse
            foreach ($df in $destFiles)
            {
                $drel = $df.FullName.Substring($destRootNorm.Length).TrimStart('\', '/')
                $base = $df.Name.ToLower()
                if (-not $sourceRelSet.Contains($drel) -and -not ($skipSet -contains $base))
                {
                    Write-Host "Removing destination-only file: $( $df.FullName )" -ForegroundColor Yellow
                    Remove-Item -LiteralPath $df.FullName -Force
                }
                elseif (-not $sourceRelSet.Contains($drel) -and ($skipSet -contains $base))
                {
                    Write-Host "Preserving skipped destination-only file: $( $df.FullName )" -ForegroundColor Yellow
                }
            }

            # optional cleanup of empty directories
            $dirs = Get-ChildItem -Path $DestRoot -Directory -Recurse | Sort-Object FullName -Descending
            foreach ($d in $dirs)
            {
                $children = Get-ChildItem -Path $d.FullName -Force -ErrorAction SilentlyContinue
                if (-not $children)
                {
                    Remove-Item -LiteralPath $d.FullName -Force -Recurse -ErrorAction SilentlyContinue
                }
            }

            Write-Host "Finished updating $DestRoot" -ForegroundColor Green
        }

        foreach ($FolderData in $FoundFoldersToOverwrite)
        {
            $oldFolder = $FolderData.DestinationFolder
            $newFolder = $FolderData.SourceFolder

            Copy-FolderReplaceWithSkips -SourceRoot $newFolder -DestRoot $oldFolder -SkipNames $FilesToSkip
        }

        foreach ($FileData in $FoundFilesToOverwrite)
        {
            $oldFile = $FileData.DestinationFile
            $newFile = $FileData.SourceFile

            Write-Host "Overwriting $newFile file..." -ForegroundColor Yellow
            Copy-Item -Force $newFile $oldFile
        }

        foreach ($FileData in $FoundFilesToAdd)
        {
            $oldFile = $FileData.DestinationFile
            $newFile = $FileData.SourceFile

            Write-Host "Adding $newFile file..." -ForegroundColor Yellow
            Copy-Item -Force $newFile $oldFile
        }
    }
    else
    {
        Write-Host "Operation aborted by user." -ForegroundColor Red
    }

    # Cleanup temporary files if not reusing
    if (-not $ReuseTempFiles -and -not $PSBoundParameters.ContainsKey('ExtracedFolder'))
    {
        Write-Host "Cleaning up temporary files..." -ForegroundColor Yellow
        if (Test-Path $TempZipPath)
        {
            Remove-Item -Recurse -Force $TempZipPath
        }
        if (Test-Path $TempExtractPath)
        {
            Remove-Item -Recurse -Force $TempExtractPath
        }
    }
    else
    {
        Write-Host "Keeping temporary files for reuse." -ForegroundColor Yellow
    }


    return $Confirm
}

function Backup-SkipFiles
{
    param(
        [string]$Root,
        [string[]]$SkipFiles,
        [string]$BackupDir
    )

    Remove-Item $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item $BackupDir -ItemType Directory | Out-Null

    Get-ChildItem $Root -File -Recurse | Where-Object {
        $SkipFiles -contains $_.Name
    } | ForEach-Object {
        $rel = $_.FullName.Substring($Root.Length).TrimStart('\')
        $dest = Join-Path $BackupDir $rel
        New-Item (Split-Path $dest) -ItemType Directory -Force | Out-Null
        Copy-Item $_.FullName $dest -Force
    }
}

function ChooseOption
{
    param (
        [Parameter(Mandatory)]
        [string]$Message,
        [Parameter(Mandatory)]
        [string[]]$Options
    )

    Write-Host $Message -ForegroundColor Yellow
    $i = 0
    foreach ($option in $Options)
    {
        Write-Host "$i. $option"
        $i++
    }

    $SelectedOption = Read-Host "Enter the ID of the option you want to choose"
    if ($SelectedOption -lt 0 -or $SelectedOption -ge $Options.Count)
    {
        Write-Host "Invalid option selected. Please try again." -ForegroundColor Red
        return ChooseOption -Message $Message -Options $Options
    }
    return $SelectedOption
}

function ChooseVersion
{
    $Version = Read-Host "Enter the GTNH version (e.g., 2.7.0, 2.7.0-beta-4)"
#    $Version = "2.8.1"
    if ($Version.Length -lt 1)
    {
        Write-Host "Version cannot be empty. Please enter a valid version." -ForegroundColor Red
        return ChooseVersion
    }
    return $Version
}

function Wrapper
{
    Write-Host "GTNH Update Script" -ForegroundColor Green
    Write-Host "Ensure that you set the correct paths in the script"
    $Version = ChooseVersion

    switch (ChooseOption -Message "Choose Update Option" -Options @("Update Server to $Version", "Update Client to $Version", "Cancel"))
#    switch (1)
    {
        0 {
            Write-Host "Updating Server"
            if (-not ($MinecraftServerPath -eq ""))
            {
                try
                {
                    $UpdateStatus = Update-Minecraft -MinecraftPath $MinecraftServerPath -Version $Version -BaseUrl $ServerBaseUrl -FoldersToOverwrite $ServerFolderNamesToOverwrite -FilesToSkip $ServerFilesToSkip -IsClient $false
                    if ($UpdateStatus -eq 0)
                    {
                        Write-Host "Server update completed." -ForegroundColor Green
                    }
                    else
                    {
                        Write-Host "Server update was aborted by user." -ForegroundColor Red
                    }
                }
                catch
                {
                    Write-Host "Error during server update: $_" -ForegroundColor Red
                }
            }
            else
            {
                Write-Host "No Minecraft server path defined. Skipping server update."
            }
        }
        1 {
            Write-Host "Updating Client"
            if (-not ($MinecraftClientPath -eq ""))
            {
                try
                {
                    $UpdateStatus = Update-Minecraft -MinecraftPath $MinecraftClientPath -Version $Version -BaseUrl $ClientBaseUrl -FoldersToOverwrite $ClientFolderNamesToOverwrite -IsClient $true
                    if ($UpdateStatus -eq 0)
                    {
                        Write-Host "Client update completed." -ForegroundColor Green
                    }
                    else
                    {
                        Write-Host "Client update was aborted by user." -ForegroundColor Red
                    }
                }
                catch
                {
                    Write-Host "Error during client update: $_" -ForegroundColor Red
                }
            }
            else
            {
                Write-Host "No Minecraft client path defined. Skipping client update."
            }
        }
        2 {
            Write-Host "Terminating"
            return
        }
        default {
            Write-Host "Invalid option selected. Please try again." -ForegroundColor Red
        }
    }

    Wrapper
}


Wrapper