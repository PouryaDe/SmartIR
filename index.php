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
if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'GET') {
    http_response_code(405);
    header('Allow: GET');
    if (defined('PHPUNIT_RUNNING')) {
        return;
    }
    exit;
}

// ==========================================
// 1. Core Logic Functions
// ==========================================

/**
 * Fetches JSON data from a given API URL with a 5-minute file-based cache.
 *
 * @param string $apiUrl    The full URL of the API endpoint.
 * @return array|null Returns decoded array on success, or null on failure.
 */
function fetchJsonFromUrl(string $apiUrl): ?array
{
    $userAgent    = str_replace(["\r", "\n"], '', $_SERVER['HTTP_USER_AGENT'] ?? 'PHP-API-Client');
    $cacheDir     = __DIR__ . '/cache/';
    $cacheFile    = $cacheDir . hash('sha256', $apiUrl . '_' . $userAgent) . '_v2.json';
    $cacheLifetime = 300; // 5 minutes

    // Garbage Collection: Clean up expired cache files (5% probability to avoid performance issues)
    if (random_int(1, 20) === 1 && is_dir($cacheDir)) {
        $files = glob($cacheDir . '*.json');
        if ($files) {
            $now = time();
            $deleted = 0;
            foreach ($files as $file) {
                if (is_file($file) && ($now - filemtime($file)) >= $cacheLifetime) {
                    @unlink($file);
                    if (++$deleted >= 50) {
                        break;
                    }
                }
            }
        }
    }

    if (file_exists($cacheFile) && (time() - filemtime($cacheFile)) < $cacheLifetime) {
        $cached = json_decode(file_get_contents($cacheFile), true);
        if (json_last_error() === JSON_ERROR_NONE && isset($cached['headers'], $cached['body'])) {
            return $cached;
        }
    }

    $ch = curl_init();
    if ($ch === false) {
        return null;
    }

    $responseHeaders = [];
    curl_setopt($ch, CURLOPT_HEADERFUNCTION, function($curl, $header) use (&$responseHeaders) {
        $len = strlen($header);
        $parts = explode(':', $header, 2);
        if (count($parts) === 2) {
            $name = strtolower(trim($parts[0]));
            $responseHeaders[$name][] = trim($parts[1]);
        }
        return $len;
    });

    curl_setopt($ch, CURLOPT_URL, $apiUrl);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_TIMEOUT, 10);
    curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 5);
    curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);
    curl_setopt($ch, CURLOPT_MAXREDIRS, 5);
    curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, true);
    // Sanitize HTTP_ACCEPT to prevent CRLF injection
    $acceptHeader = str_replace(["\r", "\n"], '', $_SERVER['HTTP_ACCEPT'] ?? 'application/json');

    curl_setopt($ch, CURLOPT_HTTPHEADER, [
        'Accept: ' . $acceptHeader,
        'User-Agent: ' . $userAgent,
    ]);

    // Apply proxy if configured (supports SOCKS5 and HTTP/HTTPS)
    $proxyUrl = defined('PROXY_URL') ? trim(PROXY_URL) : '';
    if ($proxyUrl !== '') {
        curl_setopt($ch, CURLOPT_PROXY, $proxyUrl);
        if (stripos($proxyUrl, 'socks5') === 0) {
            curl_setopt($ch, CURLOPT_PROXYTYPE, CURLPROXY_SOCKS5_HOSTNAME);
        } elseif (stripos($proxyUrl, 'http') === 0) {
            curl_setopt($ch, CURLOPT_PROXYTYPE, CURLPROXY_HTTP);
        }
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
            $result = [
                'headers' => $responseHeaders,
                'body'    => $data
            ];
            if (!is_dir($cacheDir)) {
                @mkdir($cacheDir, 0775, true);
            }
            file_put_contents($cacheFile, json_encode($result), LOCK_EX);
            return $result;
        }
    }

    return null;
}





/**
 * Renders the HTML redirect page for browser/non-API clients.
 *
 * @param string $url         The redirect destination URL.
 * @param string $finalConfig The subscription config text to output (for API clients).
 */
function renderHtmlRedirect(string $url, string $finalConfig): void
{
    $jsUrl   = json_encode($url, JSON_HEX_TAG | JSON_HEX_APOS | JSON_HEX_QUOT | JSON_HEX_AMP);
    $htmlUrl = htmlspecialchars($url, ENT_QUOTES, 'UTF-8');

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

    if ($finalConfig !== '') {
        echo "\n<!--\n" . base64_encode($finalConfig) . "\n-->\n";
    }
}

/**
 * Main subscription processing orchestrator.
 *
 * @param string $url    The redirect destination URL.
 * @param string $apiUrl The API endpoint to fetch subscription data from.
 */
function processSubscription(string $url, string $apiUrl): void
{
    $apiResult = fetchJsonFromUrl($apiUrl);

    if ($apiResult !== null && !empty($apiResult['body']['is_valid'])) {
        // Valid VPN client: send specific allowed headers from API
        $allowedHeaders = [
            'subscription-userinfo', 'profile-title', 'profile-update-interval', 
            'announce', 'support-url', 'profile-web-page-url'
        ];
        header('Content-Type: text/plain; charset=UTF-8');
        foreach ($allowedHeaders as $h) {
            if (!empty($apiResult['headers'][$h])) {
                foreach ($apiResult['headers'][$h] as $val) {
                    // Sanitize header value to prevent HTTP Response Splitting
                    $val = str_replace(["\r", "\n"], '', $val);
                    header("$h: $val", false);
                }
            }
        }
        
        // Output configs (Base64 encoded for better compatibility with VPN clients)
        $configs = (string) ($apiResult['body']['configs'] ?? '');
        
        // Encode to base64 if it's in plain text (contains protocol like vless://)
        if (strpos($configs, '://') !== false) {
            echo base64_encode($configs);
        } else {
            echo $configs;
        }
        return;
    }

    // Browser or unknown client: render HTML redirect page
    $fallbackConfigs = (string) ($apiResult['body']['configs'] ?? '');
    renderHtmlRedirect($url, $fallbackConfigs);
}

// ==========================================
// 2. Route Definitions
// ==========================================

Route::add('/([\d\w\-]+)', function ($smartlink_id) {
    $url    = 'https://' . API_DOMAIN . "/{$smartlink_id}/";
    $apiUrl = 'https://' . API_DOMAIN . "/api/{$smartlink_id}/";
    processSubscription($url, $apiUrl);
});

Route::add('/', function () {
    http_response_code(204); // No Content
});

Route::pathNotFound(function () {
    http_response_code(404);
});

Route::methodNotAllowed(function () {
    http_response_code(405);
    header('Allow: GET');
});

// Run the router if not in CLI or if explicitly requested
if (php_sapi_name() !== 'cli' || defined('RUN_ROUTER')) {
    Route::run('/');
}
