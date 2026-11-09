// Small text helpers. Strings are UTF-8 everywhere; Windows paths and APIs get UTF-16 through Widen.
#pragma once

#include <filesystem>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace apiko::text
{
std::wstring Widen(std::string_view aText);
std::string Narrow(std::wstring_view aText);
std::string PathString(const std::filesystem::path& aPath);

// At most aMax bytes, never cutting a UTF-8 character in half.
std::string Truncate(std::string_view aText, std::size_t aMax);
std::string Trim(std::string_view aText);
// ASCII lower case (enough for codes, ids and English keys).
std::string Lower(std::string_view aText);
// Lower case without accents ("¿Qué hay AQUÍ?" -> "¿que hay aqui?"), any script: for matching V's words against
// ASCII patterns and lore keys (Python's NFD-and-drop-marks).
std::string Plain(std::string_view aText);

// Python's str.format for named fields: "{name}" is replaced from aValues, "{{" and "}}" become "{" and "}".
// Unknown fields stay as they are.
std::string Format(std::string_view aTemplate, const std::map<std::string, std::string>& aValues);

// Characters (code points) in UTF-8 text.
std::size_t Length(std::string_view aText);

// Sentences for the subtitles (and the voice): port of split_sentences in bridge\apiko_voice.py. A short one
// ("Useful.") stays with the sentence before; an interjection ("Oh.") opens the next one; a long first sentence is
// cut at its first comma (or ; : —).
std::vector<std::string> SplitSentences(std::string_view aText);

// What the model said, as one clean subtitle line: no tabs or line breaks, no *stage directions*, single spaces.
std::string CleanSay(std::string_view aText);

// A whole file, or nothing when it cannot be read.
std::optional<std::string> ReadFile(const std::filesystem::path& aFile);
} // namespace apiko::text
