<?php

namespace App\Support\Help;

/** The words on the help screens, in English and Tagalog. */
class HelpWords
{
    public static function get(bool $tl): array
    {
        return $tl ? [
            'title' => 'Gabay at tulong', 'sub' => 'Hanapin kung paano gawin ang kahit ano sa system, hakbang-hakbang.',
            'search' => 'Hanapin o itanong sa sarili mong salita…', 'ask' => 'Itanong', 'try' => 'Subukan:',
            'aiTitle' => 'Magtanong sa sarili mong salita', 'aiText' => 'I-type ang tanong, kahit Taglish. Sasagot ang AI gamit lang ang mga gabay at ituturo ang tamang gabay.',
            'aiOff' => 'Hahanapin ang pinakatugmang gabay. (Puwedeng i-on ng admin ang AI answers sa Settings → AI.)',
            'aiAnswer' => 'Sagot ng AI (galing sa mga gabay)', 'bestMatch' => 'Pinakatugmang gabay', 'open' => 'Buksan', 'results' => 'Mga gabay na tugma', 'none' => 'Walang gabay na tugma. Subukan ang ibang salita.',
            'steps' => 'hakbang', 'when' => 'Kailan gagamitin', 'how' => 'Paano', 'result' => 'Resulta', 'problems' => 'Kung may problema', 'related' => 'Kaugnay na gabay',
            'helpful' => 'Nakatulong ba ang gabay na ito?', 'yes' => 'Oo', 'no' => 'Hindi', 'thanks' => 'Salamat sa sagot mo!',
            'doIt' => 'Gawin ngayon', 'back' => 'Bumalik', 'all' => 'Lahat ng gabay', 'thisPage' => 'Tulong para sa page na ito', 'close' => 'Isara', 'center' => 'Buksan ang Help guide',
            'help' => 'Tulong', 'clear' => 'Burahin',
        ] : [
            'title' => 'Help guide', 'sub' => 'Find how to do anything in the system, step by step.',
            'search' => 'Search, or ask in your own words…', 'ask' => 'Ask', 'try' => 'Try:',
            'aiTitle' => 'Ask in your own words', 'aiText' => 'Type a question, even in Taglish. The AI answers only from the guides and points you to the right one.',
            'aiOff' => 'You get the guide that matches best. (An admin can switch on AI answers in Settings → AI.)',
            'aiAnswer' => 'AI answer (from the guides)', 'bestMatch' => 'Best matching guide', 'open' => 'Open', 'results' => 'Matching guides', 'none' => 'No guide matches. Try other words.',
            'steps' => 'steps', 'when' => 'When to use it', 'how' => 'How', 'result' => 'What you get', 'problems' => 'If something goes wrong', 'related' => 'Related guides',
            'helpful' => 'Was this guide helpful?', 'yes' => 'Yes', 'no' => 'No', 'thanks' => 'Thanks for telling us!',
            'doIt' => 'Do it now', 'back' => 'Back', 'all' => 'All guides', 'thisPage' => 'Help for this page', 'close' => 'Close', 'center' => 'Open the Help guide',
            'help' => 'Help', 'clear' => 'Clear',
        ];
    }
}
