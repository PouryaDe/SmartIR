<?php

// Load configuration (including API_DOMAIN and APP_DEBUG)
if (!file_exists(__DIR__ . '/config.php')) {
    die("Configuration file missing. Please reinstall or create config.php");
}
require_once __DIR__ . '/config.php';
require_once __DIR__ . '/Route.php';

// Error reporting based on debug mode set in config.php
$debugMode = defined('APP_DEBUG') && APP_DEBUG;
ini_set('display_errors', $debugMode ? '1' : '0');
ini_set('display_startup_errors', $debugMode ? '1' : '0');
ini_set('log_errors', '1');
ini_set('error_log', __DIR__ . '/error.log');
error_reporting(E_ALL);

date_default_timezone_set('Asia/Tehran');

// Reject non-GET requests immediately
if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
    http_response_code(405);
    header('Allow: GET');
    exit;
}

// ==========================================
// 1. Core Logic Functions
// ==========================================

/**
 * Fetches JSON data from a given API URL with a 5-minute file-based cache.
 *
 * @param string $apiUrl    The full URL of the API endpoint.
 * @param string $userAgent The client User-Agent to forward to the API.
 * @return array|null Returns decoded array on success, or null on failure.
 */
function fetchJsonFromUrl(string $apiUrl, string $userAgent): ?array
{
    $cacheFile    = __DIR__ . '/cache/' . hash('sha256', $apiUrl) . '.json';
    $cacheLifetime = 300; // 5 minutes

    if (file_exists($cacheFile) && (time() - filemtime($cacheFile)) < $cacheLifetime) {
        $data = json_decode(file_get_contents($cacheFile), true);
        if (json_last_error() === JSON_ERROR_NONE) {
            return $data;
        }
    }

    $ch = curl_init();
    if ($ch === false) {
        return null;
    }

    curl_setopt($ch, CURLOPT_URL, $apiUrl);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_TIMEOUT, 10);
    curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);
    curl_setopt($ch, CURLOPT_MAXREDIRS, 5);
    curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, true);
    curl_setopt($ch, CURLOPT_HTTPHEADER, [
        'Accept: application/json',
        'User-Agent: ' . $userAgent,
    ]);

    // Apply SOCKS5 proxy if configured
    $proxyUrl = defined('PROXY_URL') ? trim(PROXY_URL) : '';
    if ($proxyUrl !== '') {
        curl_setopt($ch, CURLOPT_PROXY, $proxyUrl);
        curl_setopt($ch, CURLOPT_PROXYTYPE, CURLPROXY_SOCKS5_HOSTNAME);
    }

    $response = curl_exec($ch);

    if (curl_errno($ch)) {
        curl_close($ch);
        return null;
    }

    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);

    if ($httpCode === 200 && $response) {
        $data = json_decode($response, true);
        if (json_last_error() === JSON_ERROR_NONE) {
            file_put_contents($cacheFile, $response, LOCK_EX);
            return $data;
        }
    }

    return null;
}

/**
 * Parses the User-Agent string to identify known VPN and proxy clients.
 *
 * @param string $uaRaw The raw User-Agent string.
 * @return array Information about the parsed User-Agent.
 */
function parseUserAgent(string $uaRaw): array
{
    // Truncate first, then lowercase — avoids running strtolower on a large string
    $uaRaw = strtolower(substr($uaRaw, 0, 255));
    preg_match('/(?<name>[a-z0-9\-]{1,20})[\/\s;]+(?<ver>[\d\.]{1,20})/', $uaRaw, $m);

    $appName = $m['name'] ?? '';
    $appVer  = $m['ver']  ?? '';

    $validApps = [
        'streisand', 'v2rayng', 'happ', 'v2box', 'hiddifynext', 'hiddifynextx',
        'v2raytun', 'hiddifyng', 'shadowrocket', 'v2rayn', 'pc', 'karing', 'foxray',
    ];

    $blackApps = [
        'facebookexternalhit', 'linkedinbot', 'reactornetty', 'dalvik',
        'postmanruntime', 'dart', 'botim', 'freevpn', 'googlebot-image',
        'curl', 'unityplayer', 'trafilatura', 'v2rayx', 'sfa', 'sfi',
        'go-http-client', 'v2rayf', 'v2rayagn', '20vpn', 'stash',
        '20connect', 'quot', 'okhttp', 'googlemessages', 'bitlybot', 'instagram',
    ];

    return [
        'raw'      => $uaRaw,
        'name'     => $appName,
        'version'  => $appVer,
        'is_valid' => $appName && in_array($appName, $validApps, true),
        'is_black' => $appName && in_array($appName, $blackApps, true),
    ];
}

/**
 * Sets the necessary HTTP headers for subscription clients.
 *
 * @param array $apiResult The decoded API response.
 */
function buildSubscriptionHeaders(array $apiResult): void
{
    $usageTotal    = $apiResult['usage']['total']        ?? 0;
    $usageUpload   = $apiResult['usage']['upload']       ?? 0;
    $usageDownload = $apiResult['usage']['download']     ?? 0;
    $expireAt      = $apiResult['expire_at']             ?? 0;
    $brand         = $apiResult['creator_data']['brand'] ?? $apiResult['remark'] ?? '';

    header('Content-Type: text/plain; charset=UTF-8');
    header("subscription-userinfo: upload={$usageUpload}; download={$usageDownload}; total={$usageTotal}; expire={$expireAt}");
    header('profile-title: base64:' . base64_encode((string) $brand));
    header('profile-update-interval: 2');

    if (!empty($apiResult['creator_data']['notice'])) {
        $noticeString = str_replace(["\r", "\n"], ' ', trim($apiResult['creator_data']['notice']));
        header("announce: {$noticeString}");
    }
}

/**
 * Renders the HTML redirect page for browser/non-API clients.
 *
 * @param string $url         The redirect destination URL.
 * @param string $finalConfig The subscription config text to output (for API clients).
 */
function renderHtmlRedirect(string $url, string $finalConfig): void
{
    $jsUrl   = json_encode($url);
    $htmlUrl = htmlspecialchars($url, ENT_QUOTES, 'UTF-8');

    echo $finalConfig !== '' ? $finalConfig . "\n\n" : '';
    echo <<<HTML
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Redirecting...</title>
    <meta http-equiv="refresh" content="0;url={$htmlUrl}">
    <style>
        html, body { display: none; visibility: hidden; }
    </style>
</head>
<body>
    <script type="text/javascript">
        window.location.replace({$jsUrl});
    </script>
</body>
</html>
HTML;
}

/**
 * Main subscription processing orchestrator.
 *
 * @param string $url    The redirect destination URL.
 * @param string $apiUrl The API endpoint to fetch subscription data from.
 */
function processSubscription(string $url, string $apiUrl): void
{
    $userAgent = str_replace(["\r", "\n"], '', $_SERVER['HTTP_USER_AGENT'] ?? 'PHP-API-Client');
    $ua        = parseUserAgent($userAgent);
    $apiResult = fetchJsonFromUrl($apiUrl, $userAgent);

    if ($apiResult !== null && $ua['is_valid']) {
        // Valid VPN client: send headers and config, then stop
        buildSubscriptionHeaders($apiResult);
        echo (string) ($apiResult['configs'] ?? '');
        return;
    }

    // Browser or unknown client: render HTML redirect page
    $finalConfig = $apiResult !== null ? (string) ($apiResult['configs'] ?? '') : '';
    renderHtmlRedirect($url, $finalConfig);
}

// ==========================================
// 2. Route Definitions
// ==========================================

Route::add('/([\d\w\-]*)', function ($smartlink_id) {
    $url    = 'https://' . API_DOMAIN . "/{$smartlink_id}/";
    $apiUrl = 'https://' . API_DOMAIN . "/api/{$smartlink_id}/";
    processSubscription($url, $apiUrl);
});

Route::add('/', function () {
    http_response_code(204); // No Content
});

// Run the router
Route::run('/');
