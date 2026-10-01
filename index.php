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

// Ensure full UTF-8 encoding across all string and I/O operations
ini_set('default_charset', 'UTF-8');
if (function_exists('mb_internal_encoding')) {
    mb_internal_encoding('UTF-8');
}
if (function_exists('mb_http_output')) {
    mb_http_output('UTF-8');
}

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

    $proxyUrl     = defined('PROXY_URL') ? trim(PROXY_URL) : '';
    $acceptHeader = str_replace(["\r", "\n"], '', $_SERVER['HTTP_ACCEPT'] ?? 'application/json');

    // If proxy is set, let proxy handle routing; otherwise prefer IPv6 first (critical for Iranian networks & bypassing Cloudflare/origin IPv4 bans),
    // and fallback to IPv4 if IPv6 fails or is unavailable.
    $ipResolveAttempts = ($proxyUrl !== '')
        ? [CURL_IPRESOLVE_WHATEVER]
        : [CURL_IPRESOLVE_V6, CURL_IPRESOLVE_V4];

    foreach ($ipResolveAttempts as $ipResolve) {
        $ch = curl_init();
        if ($ch === false) {
            continue;
        }

        $responseHeaders = [];
        curl_setopt($ch, CURLOPT_HEADERFUNCTION, function($curl, $header) use (&$responseHeaders) {
            $len = strlen($header);
            $parts = explode(':', $header, 2);
            if (count($parts) === 2) {
                $name = strtolower(trim($parts[0]));
                $val  = trim($parts[1]);
                // Ensure header value is clean UTF-8
                if (!mb_check_encoding($val, 'UTF-8')) {
                    $val = mb_convert_encoding($val, 'UTF-8', 'ISO-8859-1');
                }
                $responseHeaders[$name][] = $val;
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
        curl_setopt($ch, CURLOPT_IPRESOLVE, $ipResolve);

        curl_setopt($ch, CURLOPT_HTTPHEADER, [
            'Accept: ' . $acceptHeader,
            'Accept-Charset: utf-8',
            'User-Agent: ' . $userAgent,
        ]);

        if ($proxyUrl !== '') {
            curl_setopt($ch, CURLOPT_PROXY, $proxyUrl);
            if (stripos($proxyUrl, 'socks5') === 0) {
                curl_setopt($ch, CURLOPT_PROXYTYPE, CURLPROXY_SOCKS5_HOSTNAME);
            } elseif (stripos($proxyUrl, 'http') === 0) {
                curl_setopt($ch, CURLOPT_PROXYTYPE, CURLPROXY_HTTP);
            }
        }

        $response = curl_exec($ch);
        $errno    = curl_errno($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);

        if (!$errno && $httpCode === 200 && $response) {
            // Strip UTF-8 BOM if present
            if (str_starts_with($response, "\xEF\xBB\xBF")) {
                $response = substr($response, 3);
            }
            if (!mb_check_encoding($response, 'UTF-8')) {
                $response = mb_convert_encoding($response, 'UTF-8', 'auto');
            }

            $data = json_decode($response, true);
            if (json_last_error() === JSON_ERROR_NONE) {
                $result = [
                    'headers' => $responseHeaders,
                    'body'    => $data
                ];
                if (!is_dir($cacheDir)) {
                    @mkdir($cacheDir, 0775, true);
                }
                $encoded = json_encode($result, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
                if ($encoded !== false) {
                    file_put_contents($cacheFile, $encoded, LOCK_EX);
                }
                return $result;
            }
        }
    }

    return null;
}

/**
 * Formats subscription header values to ensure Persian and Unicode characters
 * are never corrupted to '??????' across any VPN client or HTTP library.
 *
 * @param string $headerName Lowercase header name.
 * @param string $headerValue Raw header value.
 * @return array<string, string> Associative array of header_name => header_value.
 */
function formatSubscriptionHeader(string $headerName, string $headerValue): array
{
    // Sanitize header value against CRLF injection / HTTP response splitting
    $headerValue = str_replace(["\r", "\n"], '', trim($headerValue));
    if ($headerValue === '') {
        return [];
    }

    $headerName = strtolower(trim($headerName));
    $headers = [];

    if ($headerName === 'profile-title' || $headerName === 'announce') {
        if (str_starts_with($headerValue, 'base64:')) {
            // Already standard base64: format
            $headers[$headerName] = $headerValue;
            $rawText = base64_decode(substr($headerValue, 7), true);
            if ($rawText !== false && $rawText !== '') {
                $headers[$headerName . '*'] = "UTF-8''" . rawurlencode($rawText);
            }
        } elseif (preg_match('/[^\x20-\x7E]/', $headerValue)) {
            // Contains non-ASCII (Persian / Unicode). Encode to base64: and RFC 8187
            $headers[$headerName] = 'base64:' . base64_encode($headerValue);
            $headers[$headerName . '*'] = "UTF-8''" . rawurlencode($headerValue);
        } elseif (strpos($headerValue, '%') !== false && ($decoded = rawurldecode($headerValue)) !== $headerValue && preg_match('/[^\x20-\x7E]/', $decoded)) {
            // Was percent-encoded Persian/Unicode text
            $headers[$headerName] = 'base64:' . base64_encode($decoded);
            $headers[$headerName . '*'] = "UTF-8''" . rawurlencode($decoded);
        } else {
            // Standard ASCII text
            $headers[$headerName] = $headerValue;
        }
    } elseif ($headerName === 'support-url' || $headerName === 'profile-web-page-url') {
        // Encode non-ASCII characters in URLs to prevent HTTP header corruption
        if (preg_match('/[^\x20-\x7E]/', $headerValue)) {
            $headerValue = preg_replace_callback('/[^\x20-\x7E]+/', function ($matches) {
                return rawurlencode($matches[0]);
            }, $headerValue);
        }
        $headers[$headerName] = $headerValue;
    } else {
        $headers[$headerName] = $headerValue;
    }

    return $headers;
}

/**
 * Normalizes subscription configs to ensure Persian/Unicode remarks (#...)
 * in protocol links (vless, vmess, trojan, ss, etc.) are safe for Java/Android
 * and all client URI parsers without turning into '??????'.
 *
 * @param string $configs Raw subscription configs (plaintext or base64).
 * @return string Normalized configs (base64 encoded for VPN client compatibility).
 */
function normalizeConfigs(string $configs): string
{
    $configs = trim($configs);
    if ($configs === '') {
        return '';
    }

    $isBase64 = false;
    // Check if configs is already base64 encoded
    if (strpos($configs, '://') === false && preg_match('/^[A-Za-z0-9+\/=\r\n]+$/', $configs)) {
        $decoded = base64_decode($configs, true);
        if ($decoded !== false && (strpos($decoded, '://') !== false || strpos($decoded, "\n") !== false)) {
            $configs = $decoded;
            $isBase64 = true;
        }
    }

    // Preserve Clash YAML or Sing-box JSON intact
    $trimmed = ltrim($configs);
    if (str_starts_with($trimmed, '{') || str_starts_with($trimmed, 'proxies:') || str_starts_with($trimmed, 'port:')) {
        return $isBase64 ? base64_encode($configs) : $configs;
    }

    $lines = preg_split('/\r\n|\r|\n/', $configs);
    $normalizedLines = [];

    foreach ($lines as $line) {
        $line = trim($line);
        if ($line === '') {
            continue;
        }

        // Check if this line is a URI with a fragment (#remark)
        if (strpos($line, '://') !== false && strpos($line, '#') !== false) {
            $parts = explode('#', $line, 2);
            $uriPart = $parts[0];
            $remark = $parts[1] ?? '';

            // If remark contains raw non-ASCII characters (e.g. Persian/Arabic/Unicode)
            if ($remark !== '' && preg_match('/[^\x20-\x7E]/', $remark)) {
                $decoded = rawurldecode($remark);
                $remark = rawurlencode($decoded);
            }
            $line = $uriPart . '#' . $remark;
        }

        $normalizedLines[] = $line;
    }

    $result = implode("\n", $normalizedLines);

    // If it contains protocol URIs or was originally base64, return base64
    if ($isBase64 || strpos($result, '://') !== false) {
        return base64_encode($result);
    }

    return $result;
}

/**
 * Renders the HTML redirect page for browser/non-API clients.
 *
 * @param string $url         The redirect destination URL.
 * @param string $finalConfig The subscription config text to output (for API clients).
 */
function renderHtmlRedirect(string $url, string $finalConfig): void
{
    header('Content-Type: text/html; charset=UTF-8');

    $jsUrl   = json_encode($url, JSON_UNESCAPED_UNICODE | JSON_HEX_TAG | JSON_HEX_APOS | JSON_HEX_QUOT | JSON_HEX_AMP);
    $htmlUrl = htmlspecialchars($url, ENT_QUOTES, 'UTF-8');

    echo <<<HTML
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>در حال انتقال...</title>
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
        echo "\n<!--\n" . normalizeConfigs($finalConfig) . "\n-->\n";
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
                    $formattedHeaders = formatSubscriptionHeader($h, $val);
                    foreach ($formattedHeaders as $headerKey => $headerVal) {
                        header("{$headerKey}: {$headerVal}", false);
                    }
                }
            }
        }
        
        // Output configs (properly normalized and Base64 encoded for VPN clients)
        $configs = (string) ($apiResult['body']['configs'] ?? '');
        echo normalizeConfigs($configs);
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
    $queryString = str_replace(["\r", "\n"], '', $_SERVER['QUERY_STRING'] ?? '');
    if ($queryString !== '') {
        $queryString = preg_replace_callback('/[^\x21-\x7E]+/', function ($matches) {
            return rawurlencode($matches[0]);
        }, $queryString);
    }
    $query  = $queryString !== '' ? '?' . $queryString : '';
    $url    = 'https://' . API_DOMAIN . "/{$smartlink_id}/" . $query;
    $apiUrl = 'https://' . API_DOMAIN . "/api/{$smartlink_id}/" . $query;
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
