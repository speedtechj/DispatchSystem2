<?php

namespace App\Support\Connectors;

use RuntimeException;

/** The connector answered with an error; keeps its answer (for example the GRANT line). */
class ConnectorError extends RuntimeException
{
    /** @param array<mixed> $answer */
    public function __construct(string $message, int $code, public array $answer = [])
    {
        parent::__construct($message, $code);
    }
}
