# Removes trailing spaces in file and folder names
# Introduced this script as in Nextcloud it's permissable to name files/folders with
# trailing spaces, but the Windows client will subsequently fail to sync them.
[cmdletbinding(SupportsShouldProcess)]
param()

function FindAndReplace {
    [cmdletbinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({$true -eq (Test-Path $_)})]
        [String]$Path,

        [Parameter(Mandatory=$false)]
        [Bool]$Recurse = $true
    )

    $Results = @()

    $IsFolder = Test-Path $Path -PathType Container
    if($true -eq $IsFolder) {
        $GetChildrenCmd = '$Children = Get-ChildItem $Path'
        if($true -eq $Recurse) { $GetChildrenCmd += ' -Recurse' }
        Invoke-Expression $GetChildrenCmd
    }
    $ProblemChildren = $Children | Where-Object { $_.Name -match ' +$' }

    function Renamer($Item) {
        $Clone = $Item.Clone()
        $ItemType = $Clone.PSIsContainer ? "Directory" : "File"
        $OldName = $Clone.FullName
        $NewName = $Item.Name -replace ' +$'
        $Item | Rename-Item -NewName $NewName
        Write-Verbose ("Renamed {0} '{1}' to '{2}'" -f $ItemType.ToLower(), $Item.FullName, $NewName)
        Return [PSCustomObject]@{
            ItemType = $ItemType
            OldName = $OldName
            NewName = ("{0}\{1}" -f (Split-Path $OldName -Parent), $NewName) #Full new name
        }
    }
    # Rename files first to avoid invalid rename paths
    $ProblemFiles = $ProblemChildren | ? { $false -eq $_.PSIsContainer }
    $ProblemFolders = $ProblemChildren | ? { $true -eq $_.PSIsContainer }
    $Results += $ProblemFiles | % { Renamer -Item $_ }
    $Results += $ProblemFolders | % { Renamer -Item $_ }
    
    Return $Results
    <#
    foreach($Child in $ProblemFiles) {
        $NewName = $Child.Name -replace ' +$'
        $Child | Rename-Item -NewName $NewName
        Write-Verbose ("Renamed file '{0}' to '{1}'" -f $Child.FullName, $NewName)
    }

    foreach($Child in $ProblemFolders) {
        $NewName = $Child.Name -replace ' +$'
        $Child | Rename-Item -NewName $NewName
        Write-Verbose ("Renamed directory '{0}' to '{1}'" -f $Child.FullName, $NewName)
    }
    #>
}

#region NextCloud user data

$NCDataRoot = "/media/data1/nextcloud/data"
$NextCloud = Get-ChildItem $NCDataRoot -Exclude @('appdata_*','cache','files_external') -Directory
$NCRenames = $NextCloud | % { FindAndReplace -Path $_.FullName -Verbose }

#Trigger a rescan of the necessary folders, since NextCloud needs to update its DB to reflect filesystem changes
$NCRenames | Add-Member -MemberType ScriptProperty -Name RescanPath -Value {
    #Build the NC-relative path to the rename
    (Split-Path $this.OldName -Parent) -replace "^$NCDataRoot/"
}

<#
#Dedupe and rescan
foreach($RescanPath in $NCRenames.RescanPath | Select -Unique) {
    Write-Verbose "Triggering Nextcloud rescan for $RescanPath"
    sudo -u www-data /var/www/html2/nextcloud/public_html/occ files:scan --path="$RescanPath"
}
#>

#Trigger rescan of all files for each affected user
$UsersToRescan = @()
$RescanPaths = $NCRenames.RescanPath | Select -Unique
$UsersToRescan += $RescanPaths | % { ($_ -split '/')[1] }
foreach($User in $UsersToRescan | Select -Unique) {
    Write-Verbose "Triggering Nextcloud rescan for all files of user '$user'"
    sudo -u www-data /var/www/html2/nextcloud/public_html/occ files:scan --path="$user"
}

if(($UsersToRescan | Measure-Object | Select -ExpandProperty Count) -gt 0) {
    #delete all file entries that have no matching entries in the storage table.
    sudo -u www-data /var/www/html2/nextcloud/public_html/occ files:cleanup
}

#endregion
