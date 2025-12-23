param(
    [int]$Files = 5,
    [int]$Records = 1000,
    [string]$Output = "C:\ndjson_test",
    [string]$DatePrefix = (Get-Date -Format "yyyy-MM-dd")
)

# Create output folder
if (-not (Test-Path $Output)) {
    New-Item -Path $Output -ItemType Directory | Out-Null
}

function New-RandomString($length) {
    $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    -join ((1..$length) | ForEach-Object { $chars[(Get-Random -Min 0 -Max $chars.Length)] })
}

Write-Host "Generating NDJSON files at $Output using prefix $DatePrefix- ..."

for ($i = 1; $i -le $Files; $i++) {

    $filename = "$DatePrefix-file$i.ndjson"
    $fullPath = Join-Path $Output $filename

    Write-Host "Writing $fullPath ..."

    $fileContent = New-Object System.Collections.Generic.List[string]

    for ($r = 1; $r -le $Records; $r++) {

        $record = @{
            id        = New-RandomString -length 16
            timestamp = (Get-Date).ToString("o")
            category  = (Get-Random -InputObject @("alpha","beta","gamma","delta"))
            value     = Get-Random -Min 1 -Max 999999
            payload   = New-RandomString -length 450
        }

        $json = ($record | ConvertTo-Json -Compress)
        $fileContent.Add($json)
    }

    $fileContent -join "`n" | Out-File -FilePath $fullPath -Encoding utf8
}

Write-Host "`nDone!"

# powershell -ExecutionPolicy Bypass -File generate-ndjson-files.ps1 -Files 20 -Records 5000 -Output "C:\Users\moula\Documents\generate-ndjson\ndjson"
