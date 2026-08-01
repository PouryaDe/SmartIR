<?php

class Route
{
    private static array $routes = [];
    private static $pathNotFound = null;
    private static $methodNotAllowed = null;

    /**
     * Registers a new route.
     *
     * @param string          $expression Route string or regex expression.
     * @param callable        $function   Handler to call when the route matches.
     * @param string|string[] $method     Allowed HTTP method(s).
     */
    public static function add(string $expression, callable $function, string|array $method = 'get'): void
    {
        self::$routes[] = [
            'expression' => $expression,
            'function'   => $function,
            'method'     => $method,
        ];
    }

    public static function getAll(): array
    {
        return self::$routes;
    }

    public static function pathNotFound(callable $function): void
    {
        self::$pathNotFound = $function;
    }

    public static function methodNotAllowed(callable $function): void
    {
        self::$methodNotAllowed = $function;
    }

    public static function run(
        string $basepath = '',
        bool   $case_matters = false,
        bool   $trailing_slash_matters = false,
        bool   $multimatch = false
    ): void {
        // Basepath never needs a trailing slash
        $basepath = rtrim($basepath, '/');

        // Parse the current request path (parse_url may return false on malformed URIs)
        $parsed_url = parse_url($_SERVER['REQUEST_URI'] ?? '/');
        $path = '/';

        if (is_array($parsed_url) && isset($parsed_url['path'])) {
            $path = ($trailing_slash_matters || $basepath . '/' === $parsed_url['path'])
                ? $parsed_url['path']
                : rtrim($parsed_url['path'], '/');
        }

        // NOTE: urldecode intentionally omitted to prevent Path Traversal attacks
        $method            = $_SERVER['REQUEST_METHOD'];
        $path_match_found  = false;
        $route_match_found = false;

        foreach (self::$routes as $route) {
            $expression = ($basepath !== '' && $basepath !== '/')
                ? '^(' . $basepath . ')' . $route['expression'] . '$'
                : '^' . $route['expression'] . '$';

            if (!preg_match('#' . $expression . '#' . ($case_matters ? '' : 'i') . 'u', $path, $matches)) {
                continue;
            }

            $path_match_found = true;

            foreach ((array) $route['method'] as $allowedMethod) {
                if (strtolower($method) !== strtolower($allowedMethod)) {
                    continue;
                }

                // Remove full-match and optional basepath captures
                array_shift($matches);
                if ($basepath !== '' && $basepath !== '/') {
                    array_shift($matches);
                }

                $return_value = call_user_func_array($route['function'], $matches);
                if ($return_value !== null && $return_value !== false) {
                    echo $return_value;
                }

                $route_match_found = true;
                break;
            }

            if ($route_match_found && !$multimatch) {
                break;
            }
        }

        if ($route_match_found) {
            return;
        }

        if ($path_match_found && self::$methodNotAllowed) {
            $return_value = call_user_func_array(self::$methodNotAllowed, [$path, $method]);
            if ($return_value !== null && $return_value !== false) {
                echo $return_value;
            }
            return;
        }

        if (!$path_match_found && self::$pathNotFound) {
            $return_value = call_user_func_array(self::$pathNotFound, [$path]);
            if ($return_value !== null && $return_value !== false) {
                echo $return_value;
            }
        }
    }
}
