<#
  B站视频每日数据跟踪

  用法:
    powershell -ExecutionPolicy Bypass -File .\track.ps1
    powershell -ExecutionPolicy Bypass -File .\track.ps1 -ReportOnly

  -ReportOnly 只根据已保存的 snapshots.csv 生成报告，不访问网络。
#>

param(
    [switch]$ReportOnly,
    [string]$DataFile = (Join-Path $PSScriptRoot 'snapshots.csv'),
    [string]$VideoList = (Join-Path $PSScriptRoot 'videos.txt'),
    [string]$CsvReport = (Join-Path $PSScriptRoot 'report.csv'),
    [string]$MarkdownReport = (Join-Path $PSScriptRoot 'report.md'),
    [string]$DashboardData = (Join-Path $PSScriptRoot 'data.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Read-BVList {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "找不到视频列表文件: $Path"
    }

    $result = @()
    foreach ($line in Get-Content -LiteralPath $Path) {
        $item = $line.Trim()
        if ($item -and -not $item.StartsWith('#')) {
            $result += $item
        }
    }
    return @($result | Select-Object -Unique)
}

function Get-VideoStats {
    param([string]$Bvid)

    $uri = "https://api.bilibili.com/x/web-interface/view?bvid=$Bvid"
    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
        'Referer' = 'https://www.bilibili.com/'
    }
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 20
    if ($response.code -ne 0) {
        throw "接口返回错误: code=$($response.code) message=$($response.message)"
    }

    $data = $response.data
    if ($null -eq $data -or $null -eq $data.stat) {
        throw "接口返回数据为空: $Bvid"
    }

    [PSCustomObject]@{
        bvid = $Bvid
        title = [string]$data.title
        pubdate = [long]$data.pubdate
        view = [long]$data.stat.view
        reply = [long]$data.stat.reply
        like = [long]$data.stat.like
        coin = [long]$data.stat.coin
        favorite = [long]$data.stat.favorite
        share = [long]$data.stat.share
    }
}

function Get-SnapshotRows {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $rows = @(Import-Csv -LiteralPath $Path)
    foreach ($row in $rows) {
        if (-not $row.PSObject.Properties['time']) {
            $row | Add-Member -NotePropertyName 'time' -NotePropertyValue "$($row.date) 00:00"
        }
    }
    return $rows
}

function Save-Snapshot {
    param([string]$Path, [array]$Rows, [string]$Time)

    $existing = Get-SnapshotRows -Path $Path

    $kept = @($existing | Where-Object {
        -not ($_.time -eq $Time -and $_.bvid -in $Rows.bvid)
    })
    $merged = @($kept) + @($Rows)

    $pubdateByBvid = @{}
    foreach ($row in $Rows) {
        if ($row.pubdate) {
            $pubdateByBvid[$row.bvid] = $row.pubdate
        }
    }
    foreach ($row in $merged) {
        $hasPubdate = $row.PSObject.Properties['pubdate'] -and $row.pubdate
        if (-not $hasPubdate -and $pubdateByBvid.ContainsKey($row.bvid)) {
            $row | Add-Member -NotePropertyName 'pubdate' -NotePropertyValue $pubdateByBvid[$row.bvid] -Force
        }
    }

    $merged | Sort-Object time, bvid | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Get-Rate {
    param([long]$Part, [long]$Total)

    if ($Total -gt 0) {
        return [math]::Round(($Part / $Total) * 100, 2)
    }
    return 0
}

function Get-ReportRows {
    param([string]$Path, [string[]]$Order = @())

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "还没有数据文件: $Path，请先运行 track.ps1"
    }

    $rows = Get-SnapshotRows -Path $Path
    if ($rows.Count -eq 0) {
        return @()
    }

    $result = foreach ($group in ($rows | Group-Object bvid)) {
        $all = @($group.Group | Sort-Object { [datetime]$_.time })
        $first = $all[0]
        $last = $all[-1]

        $previous = $null
        if ($all.Count -ge 2) {
            $previous = $all[$all.Count - 2]
        }

        $todayBaseRows = @($all | Where-Object { $_.date -lt $last.date })
        $todayBase = $null
        if ($todayBaseRows.Count -gt 0) {
            $todayBase = $todayBaseRows | Sort-Object { [datetime]$_.time } | Select-Object -Last 1
        }

        $pubdateSeconds = if ($last.PSObject.Properties['pubdate'] -and $last.pubdate) { [long]$last.pubdate } else { 0 }
        $publishedDays = $null
        $publishDateText = $null
        if ($pubdateSeconds -gt 0) {
            $publishDate = [DateTimeOffset]::FromUnixTimeSeconds($pubdateSeconds).ToLocalTime().Date
            $publishedDays = ([datetime]$last.date - $publishDate).Days + 1
            $publishDateText = $publishDate.ToString('yyyy-MM-dd')
        }

        $dailyAvg = if ($publishedDays -gt 0) {
            [math]::Round([long]$last.view / $publishedDays, 0)
        } else {
            $null
        }

        $hourlyView = if ($null -ne $previous) {
            [long]$last.view - [long]$previous.view
        } else {
            [long]$last.view
        }

        $todayView = if ($null -ne $todayBase) {
            [long]$last.view - [long]$todayBase.view
        } else {
            [long]$last.view
        }

        $history = @($all | ForEach-Object {
            [ordered]@{
                time = $_.time
                view = [long]$_.view
                reply = [long]$_.reply
                like = [long]$_.like
                coin = [long]$_.coin
                favorite = [long]$_.favorite
                share = [long]$_.share
            }
        })

        $view = [long]$last.view

        [PSCustomObject]@{
            time = $last.time
            date = $last.date
            bvid = $last.bvid
            title = $last.title
            view = $view
            reply = [long]$last.reply
            like = [long]$last.like
            coin = [long]$last.coin
            favorite = [long]$last.favorite
            share = [long]$last.share
            hourlyView = $hourlyView
            todayView = $todayView
            publishedDays = $publishedDays
            publishDate = $publishDateText
            dailyAvg = $dailyAvg
            history = $history
            replyRate = Get-Rate ([long]$last.reply) $view
            likeRate = Get-Rate ([long]$last.like) $view
            coinRate = Get-Rate ([long]$last.coin) $view
            favoriteRate = Get-Rate ([long]$last.favorite) $view
            shareRate = Get-Rate ([long]$last.share) $view
        }
    }

    $rowsByBvid = @{}
    foreach ($row in @($result)) {
        $rowsByBvid[$row.bvid] = $row
    }

    $orderedRows = @()
    foreach ($bvid in $Order) {
        if ($rowsByBvid.ContainsKey($bvid)) {
            $orderedRows += $rowsByBvid[$bvid]
        }
    }

    foreach ($row in @($result)) {
        if ($row.bvid -notin $Order) {
            $orderedRows += $row
        }
    }

    if ($Order.Count -gt 0) {
        return @($orderedRows)
    }
    return @($result)
}

function Write-CsvReport {
    param([string]$Path, [array]$Rows)

    $Rows | ForEach-Object {
        [PSCustomObject]@{
            时间 = $_.time
            日期 = $_.date
            BV号 = $_.bvid
            标题 = $_.title
            播放 = $_.view
            评论 = $_.reply
            点赞 = $_.like
            投币 = $_.coin
            收藏 = $_.favorite
            分享 = $_.share
            本小时播放 = $_.hourlyView
            今日播放 = $_.todayView
            已发布天数 = $_.publishedDays
            日均播放 = $_.dailyAvg
            评论率 = $_.replyRate
            点赞率 = $_.likeRate
            投币率 = $_.coinRate
            收藏率 = $_.favoriteRate
            分享率 = $_.shareRate
        }
    } | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Write-MarkdownReport {
    param([string]$Path, [array]$Rows)

    $reportDate = if ($Rows.Count -gt 0) { $Rows[0].date } else { (Get-Date -Format 'yyyy-MM-dd') }
    $lines = @()
    $lines += '# B站视频数据报告'
    $lines += ''
    $lines += "数据日期：$reportDate"
    $lines += ''
    $lines += '| 时间 | BV号 | 标题 | 播放 | 评论 | 点赞 | 投币 | 收藏 | 分享 | 本小时播放 | 今日播放 | 已发布天数 | 日均播放 | 评论率 | 点赞率 | 投币率 | 收藏率 | 分享率 |'
    $lines += '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|'

    foreach ($r in $Rows) {
        $title = ($r.title -replace '\|', '\|')
        $daily = if ($null -eq $r.dailyAvg) { '-' } else { $r.dailyAvg }
        $published = if ($null -eq $r.publishedDays) { '-' } else { $r.publishedDays }
        $lines += "| $($r.time) | $($r.bvid) | $title | $($r.view) | $($r.reply) | $($r.like) | $($r.coin) | $($r.favorite) | $($r.share) | $($r.hourlyView) | $($r.todayView) | $published | $daily | $($r.replyRate)% | $($r.likeRate)% | $($r.coinRate)% | $($r.favoriteRate)% | $($r.shareRate)% |"
    }

    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

function Write-ConsoleReport {
    param([array]$Rows)

    $reportDate = if ($Rows.Count -gt 0) { $Rows[0].date } else { (Get-Date -Format 'yyyy-MM-dd') }
    Write-Host ''
    Write-Host "B站视频数据报告（$reportDate）"
    Write-Host ''

    $Rows | Format-Table -AutoSize @(
        @{ Label = '时间'; Expression = { $_.time } },
        @{ Label = 'BV号'; Expression = { $_.bvid } },
        @{ Label = '播放'; Expression = { $_.view } },
        @{ Label = '评论'; Expression = { $_.reply } },
        @{ Label = '点赞'; Expression = { $_.like } },
        @{ Label = '投币'; Expression = { $_.coin } },
        @{ Label = '收藏'; Expression = { $_.favorite } },
        @{ Label = '分享'; Expression = { $_.share } },
        @{ Label = '本小时播放'; Expression = { $_.hourlyView } },
        @{ Label = '今日播放'; Expression = { $_.todayView } },
        @{ Label = '已发布天数'; Expression = { if ($null -eq $_.publishedDays) { '-' } else { $_.publishedDays } } },
        @{ Label = '日均播放'; Expression = { if ($null -eq $_.dailyAvg) { '-' } else { $_.dailyAvg } } },
        @{ Label = '评论率%'; Expression = { $_.replyRate } },
        @{ Label = '点赞率%'; Expression = { $_.likeRate } },
        @{ Label = '投币率%'; Expression = { $_.coinRate } },
        @{ Label = '收藏率%'; Expression = { $_.favoriteRate } },
        @{ Label = '分享率%'; Expression = { $_.shareRate } }
    )
}

function Write-DashboardJson {
    param([string]$Path, [array]$Rows)

    $videos = @($Rows | ForEach-Object {
        [ordered]@{
            bvid = $_.bvid
            title = $_.title
            view = $_.view
            reply = $_.reply
            like = $_.like
            coin = $_.coin
            favorite = $_.favorite
            share = $_.share
            hourlyView = $_.hourlyView
            todayView = $_.todayView
            publishedDays = $_.publishedDays
            publishDate = $_.publishDate
            dailyAvg = $_.dailyAvg
            replyRate = $_.replyRate
            likeRate = $_.likeRate
            coinRate = $_.coinRate
            favoriteRate = $_.favoriteRate
            shareRate = $_.shareRate
            history = $_.history
        }
    })

    $updatedAt = if ($Rows.Count -gt 0) { $Rows[0].time } else { (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    $payload = [ordered]@{
        updatedAt = $updatedAt
        videos = $videos
    }

    $json = $payload | ConvertTo-Json -Depth 6
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

$chinaTimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')
$now = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, $chinaTimeZone.Id)
$snapshotTime = $now.ToString('yyyy-MM-dd HH:00')
$snapshotDate = $now.ToString('yyyy-MM-dd')

$listOrder = @()
if (Test-Path -LiteralPath $VideoList) {
    $listOrder = Read-BVList -Path $VideoList
}

if ($ReportOnly) {
    $reportRows = Get-ReportRows -Path $DataFile -Order $listOrder
    if ($reportRows.Count -eq 0) {
        Write-Host '暂无数据'
        exit 0
    }
    Write-CsvReport -Path $CsvReport -Rows $reportRows
    Write-MarkdownReport -Path $MarkdownReport -Rows $reportRows
    Write-DashboardJson -Path $DashboardData -Rows $reportRows
    Write-ConsoleReport -Rows $reportRows
    Write-Host ''
    Write-Host "CSV报告: $CsvReport"
    Write-Host "Markdown报告: $MarkdownReport"
    Write-Host "数据看板: $DashboardData"
    exit 0
}

$bvids = $listOrder
if ($bvids.Count -eq 0) {
    throw '视频列表为空'
}

Write-Host "开始抓取 $($bvids.Count) 个视频..."
$snapshots = @()

foreach ($bvid in $bvids) {
    try {
        $stats = Get-VideoStats -Bvid $bvid
        $snapshots += [PSCustomObject]@{
            time = $snapshotTime
            date = $snapshotDate
            bvid = $stats.bvid
            title = $stats.title
            pubdate = $stats.pubdate
            view = $stats.view
            reply = $stats.reply
            like = $stats.like
            coin = $stats.coin
            favorite = $stats.favorite
            share = $stats.share
        }
        Write-Host "OK $bvid 播放=$($stats.view) 评论=$($stats.reply)"
    } catch {
        Write-Warning "$bvid 抓取失败: $($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds 300
}

if ($snapshots.Count -eq 0) {
    throw '全部视频抓取失败'
}

Save-Snapshot -Path $DataFile -Rows $snapshots -Time $snapshotTime
Write-Host "已保存 $($snapshots.Count) 条记录"

$reportRows = Get-ReportRows -Path $DataFile -Order $listOrder
Write-CsvReport -Path $CsvReport -Rows $reportRows
Write-MarkdownReport -Path $MarkdownReport -Rows $reportRows
Write-DashboardJson -Path $DashboardData -Rows $reportRows
Write-ConsoleReport -Rows $reportRows
Write-Host ''
Write-Host "CSV报告: $CsvReport"
Write-Host "Markdown报告: $MarkdownReport"
Write-Host "数据看板: $DashboardData"
