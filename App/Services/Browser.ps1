function Initialize-BrowserAssemblies {
    Ensure-WebViewDependencies
    $dir = Resolve-AppPath $config.webView2.assemblyDirectory
    $native = Resolve-AppPath $config.webView2.nativeDirectory
    if (!(Test-Path "$native/WebView2Loader.dll")) { throw 'WebView2Loader.dllがありません。' }
    try {
        if (!('Kijitama.WebViewLoader' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Reflection;
using System.Runtime.InteropServices;
namespace Kijitama {
    public static class WebViewLoader {
        private static IntPtr handle;
        private static Assembly registeredAssembly;
        public static void Register(Assembly assembly, string path) {
            if (registeredAssembly == assembly) return;
            if (registeredAssembly != null) throw new InvalidOperationException("WebView2 loader is already registered.");
            handle = NativeLibrary.Load(path);
            NativeLibrary.SetDllImportResolver(assembly, Resolve);
            registeredAssembly = assembly;
        }
        private static IntPtr Resolve(string name, Assembly assembly, DllImportSearchPath? searchPath) {
            return String.Equals(name, "WebView2Loader.dll", StringComparison.OrdinalIgnoreCase)
                || String.Equals(name, "WebView2Loader", StringComparison.OrdinalIgnoreCase)
                ? handle : IntPtr.Zero;
        }
    }
}
"@
        }
        $coreAssembly=[Reflection.Assembly]::LoadFrom((Join-Path $dir 'Microsoft.Web.WebView2.Core.dll'))
        [Kijitama.WebViewLoader]::Register($coreAssembly,[IO.Path]::GetFullPath((Join-Path $native 'WebView2Loader.dll')))
        [Reflection.Assembly]::LoadFrom((Join-Path $dir 'Microsoft.Web.WebView2.Wpf.dll')) | Out-Null
        [void][Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString()
    }
    catch {
        $cause=$_.Exception
        while($cause.InnerException){$cause=$cause.InnerException}
        $details=$cause.GetType().FullName+' / HRESULT=0x'+('{0:X8}' -f $cause.HResult)+' / '+$cause.Message
        throw ('WebView2の起動準備に失敗しました。Runtimeの未導入とは限りません。'+[Environment]::NewLine+
            'PowerShell '+$PSVersionTable.PSVersion+' / '+[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture+
            [Environment]::NewLine+$details)
    }
}
function Get-NavigationDeniedMessage([string]$Url,[bool]$Frame=$false) {
    $uri=$null
    if([Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -and $uri.Scheme -eq 'http') {
        if($Frame){return 'http:// の埋め込みコンテンツはセキュリティ上の理由で読み込めません。'}
        return 'http:// のURLはセキュリティ上の理由でアクセスできません。https:// を使用してください。'
    }
    if($Frame){return '許可されていない埋め込みフレームをブロックしました: '+$Url}
    return '閲覧設定で許可されていないURLのため表示できません: '+$Url
}
function Navigate-Browser([string]$Url) {
    if ($script:addressSuggestionTimer) { $script:addressSuggestionTimer.Stop() }
    $script:addressUserEditing=$false
    $Url=$Url.Trim()
    if ($Url -and $Url -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*:') { $Url='https://'+$Url }
    if (!(Test-AllowedUrl $Url)) { $ui.Status.Text = Get-NavigationDeniedMessage $Url; return }
    if (!$script:browser -or !$script:browser.CoreWebView2) { throw 'ブラウザーの準備中です。読み込み完了後に再度お試しください。' }
    $ui.Address.IsDropDownOpen=$false
    $script:browser.CoreWebView2.Navigate($Url)
    $ui.Status.Text='移動しています: '+$Url
}
function Open-ProfileBrowser {
    if ($script:pdfTask -or $script:imageTask) { throw '保存・撮影が完了してからプロフィールを切り替えてください。' }
    if ($script:summaryStage) { Stop-PageSummary 'プロフィールを切り替えたため中止しました。' }
    if ($ui.SummaryText) { $ui.SummaryText.Clear(); $ui.SummarySource.Text='' }
    $script:addressUserEditing=$false
    if ($script:addressSuggestionTimer) { $script:addressSuggestionTimer.Stop() }
    Load-History; Load-Favorites; Refresh-Favorites; Refresh-History
    Restore-ProfileTabs
}


