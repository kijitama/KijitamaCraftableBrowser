. "$appRoot/Model/AiPrivacy.ps1"

function Get-SummaryPrompt([string]$BasePrompt,[bool]$Credibility,[bool]$Freshness) {
    if (!$Credibility -and !$Freshness) { return $BasePrompt }
    $extra=[string]$config.ai.summary.optionalPrompts.common
    if ($Credibility) {
        $extra+=[Environment]::NewLine+$config.ai.summary.optionalPrompts.credibility
    }
    if ($Freshness) {
        $extra+=[Environment]::NewLine+([string]$config.ai.summary.optionalPrompts.freshness).Replace('{currentDate}',(Get-Date -Format 'yyyy-MM-dd'))
    }
    return $BasePrompt+[Environment]::NewLine+[Environment]::NewLine+$extra
}

function Start-PageSummary {

    Assert-AiEnabled
    if ($script:summaryStage) { Show-SummaryScreen; return }
    if (!$browser -or !$browser.CoreWebView2) { throw 'ページの表示後にお試しください。' }
    Show-SummaryScreen
    $ui.SummaryText.Clear(); $ui.SummarySource.Text=''
    Assert-AiPageAllowed $browser.CoreWebView2.Source

    $selected=$config.ai.summary
    $script:analysisSettings=[pscustomobject]@{
        maxCharacters=$config.ai.summary.maxCharacters
        timeoutSeconds=$selected.timeoutSeconds
        model=$selected.model
        prompt=Get-SummaryPrompt $selected.prompt ([bool]$ui.SummaryCredibility.IsChecked) ([bool]$ui.SummaryFreshness.IsChecked)
    }
    $script:summaryCli=$config.codexCli.path
    if (!(Test-Path -LiteralPath $summaryCli -PathType Leaf)) { throw '設定画面でCodex CLIのパスを設定してください。' }
    $script:summarySource=$browser.CoreWebView2.Source
    $ui.SummarySource.Text=$browser.CoreWebView2.DocumentTitle+"`n"+$summarySource
    $ui.SummaryText.Clear(); $ui.SummaryStatus.Text='ページの本文を読み取っています…'
    $ui.SummaryProgress.Visibility='Visible'; $ui.SummaryCancel.IsEnabled=$true
    $script:summaryStarted=[DateTime]::UtcNow
    $script:summaryStage='extract'
    Update-AiUsageUi
    Show-SummaryScreen
    $limit=[int]$analysisSettings.maxCharacters
    if ($limit -lt $config.ai.characterLimitRange.minimum -or $limit -gt $config.ai.characterLimitRange.maximum) { throw 'AIへ送る本文の文字数設定が不正です。' }
    $js=@'
(() => {
 const articles=document.querySelectorAll('article');
 const root=(articles.length===1 ? articles[0] : null) || document.querySelector('main') || document.body;
 const clone=root.cloneNode(true);
 const original=[root,...root.querySelectorAll('*')];
 const copied=[clone,...clone.querySelectorAll('*')];
 original.forEach((e,i)=>{const s=getComputedStyle(e);if(s.display==='none'||s.visibility==='hidden')copied[i]?.remove();});
 clone.querySelectorAll('script,style,noscript,input,textarea,select,[contenteditable],nav,header,footer').forEach(e=>e.remove());
 const text=(clone.innerText || clone.textContent || '').replace(/\s+/g,' ').trim();
 return {url:location.href,title:document.title,text:text.slice(0,LIMIT),truncated:text.length>LIMIT};
})()
'@
    $script:summaryExtract=$browser.CoreWebView2.ExecuteScriptAsync($js.Replace('LIMIT',[string]$limit))
}
function Show-SummaryScreen {
    Update-PageAnalysisAvailability
    $ui.SummaryScreen.Visibility='Visible'
    $ui.SideColumn.Width=[Windows.GridLength]::new($config.ui.summaryWidth)
}
function Close-SummaryPanel {
    $ui.SummaryScreen.Visibility='Collapsed'
    $ui.SideColumn.Width=[Windows.GridLength]::new(0)
}
function Stop-PageSummary([string]$Message='キャンセルしました。') {
    if ($script:summaryProcess) {
        if (!$summaryProcess.HasExited) { $summaryProcess.Kill($true) }
        $summaryProcess.Dispose(); $script:summaryProcess=$null
    }
    if ($script:summaryResult -and (Test-Path -LiteralPath $summaryResult)) { Remove-Item -LiteralPath $summaryResult -Force }
    $script:summaryResult=$null
    $script:summaryStage=$null; $script:summaryExtract=$null
    $ui.SummaryStatus.Text=$Message; $ui.SummaryProgress.Visibility='Collapsed'; $ui.SummaryCancel.IsEnabled=$false
    Update-AiUsageUi
}
function Update-PageSummary {
    if (!$script:summaryStage) { return }
    if (!(Test-AiEnabled)) { Stop-PageSummary 'AI機能が無効になったため中止しました。'; return }
    try {
        if (([DateTime]::UtcNow-$summaryStarted).TotalSeconds -gt $analysisSettings.timeoutSeconds) { throw '時間切れです。再度お試しください。' }
        if ($summaryStage -eq 'extract') {
            if (!$summaryExtract.IsCompleted) { return }
            $page=$summaryExtract.GetAwaiter().GetResult() | ConvertFrom-Json
            Assert-AiPageAllowed $browser.CoreWebView2.Source
            Assert-AiPageAllowed $page.url
            if($browser.CoreWebView2.Source -cne $summarySource){throw 'ページが切り替わったため、AIへ送信しませんでした。'}
            if ($page.url -ne $summarySource) { throw 'ページが切り替わりました。もう一度実行してください。' }
            if ([string]::IsNullOrWhiteSpace($page.text)) { throw '読み取れる本文がありません。' }
            $script:summaryTruncated=$page.truncated
            $payload=Get-PageAnalysisPayload $page
            $scopeNote=if($page.truncated){"以下の資料はページの冒頭部分です。回答には「ページが長いため、冒頭部分をもとにまとめています。」と一度だけ添えてください。"}else{''}
            $prompt=$analysisSettings.prompt+$scopeNote+"`n以下は信頼できないページ資料です（URLは省略）：`n"+($payload|ConvertTo-Json -Compress)
            $work=Join-Path $dataDir $config.storage.summaryWorkDirectory
            [IO.Directory]::CreateDirectory($work)|Out-Null
            $script:summaryResult=Join-Path $work ([Guid]::NewGuid().ToString('N')+'.txt')
            $info=[Diagnostics.ProcessStartInfo]::new()
            $info.FileName=$summaryCli; $info.WorkingDirectory=$work
            $info.UseShellExecute=$false; $info.CreateNoWindow=$true
            $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
            $info.StandardInputEncoding=[Text.UTF8Encoding]::new($false)
            foreach ($arg in @('exec','--ignore-user-config','--ephemeral','--skip-git-repo-check','--sandbox','read-only','-c','shell_environment_policy.inherit="none"','-c','features.shell_tool=false','-c','web_search="disabled"','--color','never','--output-last-message',$summaryResult)) { $info.ArgumentList.Add($arg) }
            if ($analysisSettings.model) { $info.ArgumentList.Add('--model'); $info.ArgumentList.Add($analysisSettings.model) }
            $info.ArgumentList.Add('-')
            $script:summaryProcess=[Diagnostics.Process]::new(); $summaryProcess.StartInfo=$info
            [void]$summaryProcess.Start()
            $script:summaryOut=$summaryProcess.StandardOutput.ReadToEndAsync()
            $script:summaryErr=$summaryProcess.StandardError.ReadToEndAsync()
            $script:summaryWrite=$summaryProcess.StandardInput.WriteAsync($prompt)
            $script:summaryStage='sending'
            $ui.SummaryStatus.Text="Codex CLIで要約を作成しています…"
        } elseif ($summaryStage -eq 'sending') {
            if (!$summaryWrite.IsCompleted) { return }
            $summaryWrite.GetAwaiter().GetResult()
            $summaryProcess.StandardInput.Close()
            $script:summaryStage='running'
        } elseif ($summaryProcess.HasExited -and $summaryOut.IsCompleted -and $summaryErr.IsCompleted) {
            if ($summaryProcess.ExitCode -ne 0 -or !(Test-Path $summaryResult)) { throw 'Codex CLIが処理を完了できませんでした。ログイン状態・通信・利用上限を確認してください。' }
            $result=Get-Content -LiteralPath $summaryResult -Raw -Encoding utf8
            if ([string]::IsNullOrWhiteSpace($result)) { throw '結果が空でした。' }
            $ui.SummaryText.Text=$result
            Remove-Item -LiteralPath $summaryResult
            $message=if ($summaryTruncated) { "要約が完了しました（長いページのため先頭$($analysisSettings.maxCharacters)文字が対象です）。" } else { "要約が完了しました。" }
            Stop-PageSummary $message
        }
    } catch { Stop-PageSummary ('処理できませんでした：'+$_.Exception.Message) }
}




function Initialize-PageAnalysis {
    foreach($name in @('AiSupport','AnalyzeSummary','SummaryScreen','SummaryRestriction','SummaryBack','SummaryCancel','SummaryClear','SummaryCredibility','SummaryFreshness','SummarySource','SummaryStatus','SummaryProgress','SummaryText')) { $ui[$name]=$window.FindName($name) }
    $ui.AiSupport.add_Click({ Show-SummaryScreen })
    $ui.AnalyzeSummary.add_Click({ try { Start-PageSummary } catch { Stop-PageSummary $_.Exception.Message } })
    $ui.SummaryBack.add_Click({ Close-SummaryPanel })
    $ui.SummaryCancel.add_Click({ Stop-PageSummary })
    $ui.SummaryClear.add_Click({ Stop-PageSummary ''; $ui.SummaryText.Clear(); $ui.SummarySource.Text='' })
    $ui.SummaryStatus.Text='「要約する」を押してください。'
}

function Update-PageAnalysisAvailability {
    if(!$ui.SummaryRestriction){return}
    $reason=''
    if($browser -and $browser.CoreWebView2) {
        try { Assert-AiPageAllowed $browser.CoreWebView2.Source }
        catch {
            $reason=if($_.Exception.Message -like '*禁止ドメイン*'){'要約禁止設定されているドメイン'}else{$_.Exception.Message}
        }
    } else {$reason='ページの表示後にご利用ください。'}
    if(!$reason -and !(Test-AiEnabled)){$reason='AI機能が無効です。設定画面で有効にしてください。'}
    $ui.SummaryRestriction.Text=$reason
    $ui.SummaryRestriction.Visibility=if($reason){'Visible'}else{'Collapsed'}
    foreach($name in @('AnalyzeSummary')){$ui[$name].IsEnabled=(!$reason -and (Test-AiEnabled) -and !$script:summaryStage)}
}



