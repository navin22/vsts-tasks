Trace-VstsEnteringInvocation $MyInvocation
Import-VstsLocStrings "$PSScriptRoot\Task.json"

function Write-Exception
{
    param (
        $exception
    )

    if($exception.Message) 
    {
        Write-Error ($exception.Message)
    }
    else 
    {
        Write-Error ($exception)
    }
    throw
}

function Get-SingleFile
{
    param (
        [string]$pattern
    )

    Write-Verbose "Finding files with pattern $pattern"
    $files = Find-VstsFiles -LegacyPattern "$pattern"
    Write-Verbose "Matched files = $files"

    if ($files -is [system.array])
    {
        throw (Get-VstsLocString -Key "Foundmorethanonefiletodeploywithsearchpattern0Therecanbeonlyone" -ArgumentList $pattern)
    }
    else
    {
        if (!$files)
        {
            throw (Get-VstsLocString -Key "Nofileswerefoundtodeploywithsearchpattern0" -ArgumentList $pattern)
        }
        return $files
    }
}

function Add-BatchFilesPathToSqlFilesPath
{
    param (
        [string]$sqlBatchFiles,
        [string]$sqlScriptsWithExpandedPath
    )

    $sqlBatchFilesPath = $sqlBatchFiles -split ";"
    foreach ($sqlBatchFile in $sqlBatchFilesPath)
    {
        if ((Test-Path -Path $sqlBatchFile) -eq $true)
        {
            $sqlScriptsWithExpandedPath = $sqlScriptsWithExpandedPath + $sqlBatchFile + "; "
        }
    }

    return $sqlScriptsWithExpandedPath
}

function New-SqlBatchFilesDestDirectory
{
    param (
        [string]$directoryName
    )

    if ((Test-Path -Path $directoryName) -eq $true) 
    {
        Remove-Item -Path $directoryName -Force | Out-Null
    }

    New-Item -Path $directoryName -ItemType Directory | Out-Null
}

$taskType = Get-VstsInput -Name "TaskType" -Require
$dacpacFile = Get-VstsInput -Name "dacpacFile"
$sqlFiles = Get-VstsInput -Name "sqlFile" 
$executeInTransaction = Get-VstsInput -Name "ExecuteInTransaction" -AsBool
$exclusiveLock = Get-VstsInput -Name "ExclusiveLock" -AsBool
$appLockName = Get-VstsInput -Name "AppLockName" 
$inlineSql = Get-VstsInput -Name "inlineSql"
$targetMethod = Get-VstsInput -Name "targetMethod"
$serverName = Get-VstsInput -Name "serverName" -Require
$databaseName = Get-VstsInput -Name "databaseName" -Require
$authscheme = Get-VstsInput -Name "authscheme" -Require
$sqlUsername = Get-VstsInput -Name "sqlUsername"
$sqlPassword = Get-VstsInput -Name "sqlPassword"
$connectionString = Get-VstsInput -Name "connectionString"
$publishProfile = Get-VstsInput -Name "publishProfile"
$additionalArguments = Get-VstsInput -Name "additionalArguments"
$additionalArgumentsSql = Get-VstsInput -Name "additionalArgumentsSql"


Import-Module $PSScriptRoot\ps_modules\TaskModuleSqlUtility
. "$PSScriptRoot\Utility.ps1"
. "$PSScriptRoot\GenerateSqlBatchFiles.ps1"


Try
{

    if ($taskType -ne "dacpac")
    {
        $additionalArguments = $additionalArgumentsSql
        $targetMethod = "server"
    }

    if($sqlUsername -and $sqlPassword)
    {
        $secureAdminPassword = "$sqlPassword" | ConvertTo-SecureString  -AsPlainText -Force
        $sqlServerCredentials = New-Object System.Management.Automation.PSCredential ("$sqlUserName", $secureAdminPassword)
    }

    if ($taskType -eq "dacpac")
    {
        $dacpacFile = Get-SingleFile -pattern $dacpacFile
        Invoke-DacpacDeployment -dacpacFile $dacpacFile -targetMethod $targetMethod -serverName $serverName -databaseName $databaseName -authscheme $authscheme -sqlServerCredentials $sqlServerCredentials -connectionString $connectionString -publishProfile $publishProfile -additionalArguments $additionalArguments
    }
    else
    {
        if ($taskType -eq "sqlQuery")
        {
            if ($executeInTransaction)
            {
                if ($exclusiveLock -and ($appLockName.Length -eq 0))
                {
                    Write-Error "Invalid Applock name. exclusiveLock: $exclusiveLock, appLockName: $appLockName"
                }
                
                $batch = 1
                $destPath = [System.IO.Path]::Combine($env:SYSTEM_DEFAULTWORKINGDIRECTORY, "batchdir")
                New-SqlBatchFilesDestDirectory -directoryName $destPath

                $sqlScriptsWithExpandedPath = ""
                $sqlScriptFiles = $sqlFiles -split ";"
                foreach ($sqlScript in $sqlScriptFiles) 
                {
                    $sqlScript = $sqlScript.Trim()
                    if (-not [string]::IsNullOrEmpty($sqlScript)) 
                    {
                        $sqlScript = Get-SingleFile -pattern $sqlScript
                        $batchFiles = Create-BatchFilesForSqlFile -sqlFilePath $sqlScript -destPath $destPath -batch $batch
                        $sqlScriptsWithExpandedPath = Add-BatchFilesPathToSqlFilesPath -sqlBatchFiles $batchFiles -sqlScriptsWithExpandedPath $sqlScriptsWithExpandedPath
                        $batch = [int]$batch + 1
                    }
                }
                Write-Verbose "Executing sql scripts $sqlScriptsWithExpandedPath under transaction using app lock $appLockName"
                Invoke-SqlScriptsInTransaction -serverName $serverName -databaseName $databaseName -appLockName $appLockName -sqlscriptFiles $sqlScriptsWithExpandedPath -authscheme $authscheme -sqlServerCredentials $sqlServerCredentials -additionalArguments $additionalArguments
                Remove-Item -Path $destPath -Force
            } 
            else 
            {
                $sqlScriptFiles = $sqlFiles -split ";"
                foreach ($sqlScript in $sqlScriptFiles) 
                {
                    $sqlScript = $sqlScript.Trim()
                    if (-not [string]::IsNullOrEmpty($sqlScript)) 
                    {
                        $sqlScript = Get-SingleFile -pattern $sqlScript
                        Invoke-SqlQueryDeployment -taskType $taskType -sqlFile $sqlScript -serverName $serverName -databaseName $databaseName -authscheme $authscheme -sqlServerCredentials $sqlServerCredentials -additionalArguments $additionalArguments
                    }
                }
            }
        }
        else 
        {
            Invoke-SqlQueryDeployment -taskType $taskType -inlineSql $inlineSql -serverName $serverName -databaseName $databaseName -authscheme $authscheme -sqlServerCredentials $sqlServerCredentials -additionalArguments $additionalArguments
        }
    }
}
Catch [System.Management.Automation.CommandNotFoundException]
{
    if ($_.Exception.CommandName -ieq "Invoke-Sqlcmd")
    {
        Write-Error (Get-VstsLocString -Key "SQLPowershellModuleisnotinstalledonyouragentmachine")
        Write-Error (Get-VstsLocString -Key "InstallPowershellToolsharedManagementObjectsdependency")
        Write-Error (Get-VstsLocString -Key "RestartagentmachineafterinstallingtoolstoregisterModulepathupdates")
        Write-Error (Get-VstsLocString -Key "RunImportModuleSQLPSonyouragentPowershellprompt")
    }

    Write-Exception($_.Exception)
}
Catch [Exception]
{
    Write-Exception($_.Exception)
}
