<?php

namespace App\Support\Ai;

use RuntimeException;

/** The AI could not answer (no key, switched off, monthly limit reached, or the service failed). The message is safe to show. */
class AiUnavailable extends RuntimeException {}
