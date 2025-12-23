param(
    [int]$Files = 100,
    [int]$Records = 1000,
    [string]$Output = "C:\Users\moula\OneDrive\Documents\_Dev\data\ndjson",
    [string]$DatePrefix = (Get-Date -Format "yyyy-MM-dd")
)

if (-not (Test-Path $Output)) {
    New-Item -Path $Output -ItemType Directory | Out-Null
}

function New-RandomString($length) {
    $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    -join ((1..$length) | ForEach-Object { $chars[(Get-Random -Min 0 -Max $chars.Length)] })
}

Write-Host "Generating small NDJSON files ..."

for ($i = 1; $i -le $Files; $i++) {

    $filename = "$DatePrefix-file$i.ndjson"
    $filePath = Join-Path $Output $filename

    Write-Host "Writing $filePath ..."

    $lines = New-Object System.Collections.Generic.List[string]

    for ($r = 1; $r -le $Records; $r++) {

        $record = @{
            id   = New-RandomString -length 8
            ts   = (Get-Date).ToString("o")
            data = New-RandomString -length 20
        }

        $json = ($record | ConvertTo-Json -Compress)
        $lines.Add($json)
    }

    $lines -join "`n" | Out-File -FilePath $filePath -Encoding utf8
}

Write-Host "`nDone!"
