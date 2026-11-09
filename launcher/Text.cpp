#include "Text.hpp"

#include <Windows.h>

#include <algorithm>
#include <fstream>
#include <initializer_list>
#include <regex>
#include <sstream>

namespace apiko::text
{
std::wstring Widen(std::string_view aText)
{
    if (aText.empty())
        return {};
    int size = MultiByteToWideChar(CP_UTF8, 0, aText.data(), static_cast<int>(aText.size()), nullptr, 0);
    std::wstring wide(size, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, aText.data(), static_cast<int>(aText.size()), wide.data(), size);
    return wide;
}

std::string Narrow(std::wstring_view aText)
{
    if (aText.empty())
        return {};
    int size =
        WideCharToMultiByte(CP_UTF8, 0, aText.data(), static_cast<int>(aText.size()), nullptr, 0, nullptr, nullptr);
    std::string narrow(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, aText.data(), static_cast<int>(aText.size()), narrow.data(), size, nullptr,
                        nullptr);
    return narrow;
}

std::string PathString(const std::filesystem::path& aPath)
{
    return Narrow(aPath.native());
}

std::string Truncate(std::string_view aText, std::size_t aMax)
{
    if (aText.size() <= aMax)
        return std::string(aText);
    std::size_t cut = aMax;
    // Back up over UTF-8 continuation bytes (10xxxxxx).
    while (cut > 0 && (static_cast<unsigned char>(aText[cut]) & 0xC0) == 0x80)
        --cut;
    return std::string(aText.substr(0, cut));
}

std::string Trim(std::string_view aText)
{
    constexpr std::string_view space = " \t\r\n";
    auto start = aText.find_first_not_of(space);
    if (start == std::string_view::npos)
        return {};
    auto end = aText.find_last_not_of(space);
    return std::string(aText.substr(start, end - start + 1));
}

std::string Lower(std::string_view aText)
{
    std::string lower(aText);
    std::transform(lower.begin(), lower.end(), lower.begin(),
                   [](char c) { return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c; });
    return lower;
}

std::string Plain(std::string_view aText)
{
    auto wide = Widen(aText);
    if (wide.empty())
        return {};
    // MAP_COMPOSITE splits accented letters into base letter + combining mark; the marks are dropped.
    int size = FoldStringW(MAP_COMPOSITE, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0);
    std::wstring folded(size > 0 ? size : 0, L'\0');
    if (size <= 0 || FoldStringW(MAP_COMPOSITE, wide.c_str(), static_cast<int>(wide.size()), folded.data(), size) <= 0)
        folded = wide;
    std::wstring plain;
    plain.reserve(folded.size());
    for (wchar_t c : folded)
        if (c < 0x0300 || c > 0x036F)
            plain += c;
    if (plain.empty())
        return {};
    std::wstring lower(plain.size(), L'\0');
    int length = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, plain.c_str(), static_cast<int>(plain.size()),
                               lower.data(), static_cast<int>(lower.size()), nullptr, nullptr, 0);
    return Narrow(length > 0 ? std::wstring_view(lower.data(), length) : std::wstring_view(plain));
}

std::string Format(std::string_view aTemplate, const std::map<std::string, std::string>& aValues)
{
    std::string out;
    out.reserve(aTemplate.size());
    for (std::size_t i = 0; i < aTemplate.size(); ++i)
    {
        char c = aTemplate[i];
        if ((c == '{' || c == '}') && i + 1 < aTemplate.size() && aTemplate[i + 1] == c)
        {
            out += c;
            ++i;
            continue;
        }
        if (c == '{')
        {
            auto close = aTemplate.find('}', i);
            if (close != std::string_view::npos)
            {
                auto it = aValues.find(std::string(aTemplate.substr(i + 1, close - i - 1)));
                if (it != aValues.end())
                {
                    out += it->second;
                    i = close;
                    continue;
                }
            }
        }
        out += c;
    }
    return out;
}

std::size_t Length(std::string_view aText)
{
    return static_cast<std::size_t>(
        std::count_if(aText.begin(), aText.end(), [](char c) { return (static_cast<unsigned char>(c) & 0xC0) != 0x80; }));
}

namespace
{
constexpr std::size_t MinSentenceChars = 12; // shorter sentences are joined to the next one
constexpr std::size_t FirstChunkMax = 50;    // a longer first sentence is cut at its first comma
constexpr std::string_view Ellipsis = "\xE2\x80\xA6"; // …
constexpr std::string_view Dash = "\xE2\x80\x94";     // —

bool IsSpace(char c)
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

bool EndsWithAny(std::string_view aText, std::initializer_list<std::string_view> aEnds)
{
    for (auto end : aEnds)
        if (aText.size() >= end.size() && aText.substr(aText.size() - end.size()) == end)
            return true;
    return false;
}

// Python's re.split(r"(?<=[.!?…])\s+"): split at whitespace that follows a sentence end.
std::vector<std::string> SplitAfter(std::string_view aText, std::initializer_list<std::string_view> aEnds)
{
    std::vector<std::string> pieces;
    std::size_t start = 0;
    for (std::size_t i = 0; i < aText.size(); ++i)
    {
        if (!IsSpace(aText[i]) || !EndsWithAny(aText.substr(0, i), aEnds))
            continue;
        auto end = i;
        while (end < aText.size() && IsSpace(aText[end]))
            ++end;
        pieces.emplace_back(aText.substr(start, i - start));
        start = end;
        i = end - 1;
    }
    pieces.emplace_back(aText.substr(start));
    return pieces;
}

// "Oh.", "Hmm...", "Vaya!": only an interjection.
bool IsInterjection(std::string_view aPiece)
{
    std::string word(aPiece);
    while (!word.empty())
    {
        if (word.back() == '.' || word.back() == '!' || word.back() == '?')
            word.pop_back();
        else if (EndsWithAny(word, {Ellipsis}))
            word.resize(word.size() - Ellipsis.size());
        else
            break;
    }
    static const std::regex pattern(R"(oh+|ah+|eh|uh+|um+|hm+|mm+|huh|aha|aja|vaya)");
    return !word.empty() && std::regex_match(Plain(word), pattern);
}
} // namespace

std::vector<std::string> SplitSentences(std::string_view aText)
{
    std::vector<std::string> chunks;
    std::string lead; // interjections waiting for the sentence they open
    for (auto& piece : SplitAfter(Trim(aText), {".", "!", "?", Ellipsis}))
    {
        if (piece.empty())
            continue;
        if (IsInterjection(piece))
        {
            lead = Trim(lead + " " + piece);
            continue;
        }
        if (!lead.empty())
        {
            piece = lead + " " + piece;
            lead.clear();
        }
        if (!chunks.empty() && (Length(piece) < MinSentenceChars || Length(chunks.back()) < MinSentenceChars))
            chunks.back() += " " + piece;
        else
            chunks.push_back(piece);
    }
    if (!lead.empty()) // an interjection at the very end: nothing after it to open
    {
        if (chunks.empty())
            chunks.push_back(lead);
        else
            chunks.back() += " " + lead;
    }
    if (chunks.size() > 1 && Length(chunks.back()) < MinSentenceChars)
    {
        auto last = chunks.back();
        chunks.pop_back();
        chunks.back() += " " + last;
    }
    if (!chunks.empty() && Length(chunks[0]) > FirstChunkMax)
    {
        // The first cut (whitespace after , ; : —) that leaves at least MinSentenceChars on each side.
        const auto first = chunks[0];
        for (std::size_t i = 0; i < first.size(); ++i)
        {
            if (!IsSpace(first[i]) || !EndsWithAny(std::string_view(first).substr(0, i), {",", ";", ":", Dash}))
                continue;
            auto end = i;
            while (end < first.size() && IsSpace(first[end]))
                ++end;
            if (Length(first.substr(0, i)) >= MinSentenceChars && Length(first.substr(end)) >= MinSentenceChars)
            {
                chunks[0] = first.substr(0, i);
                chunks.insert(chunks.begin() + 1, first.substr(end));
                break;
            }
            i = end - 1;
        }
    }
    return chunks;
}

std::string CleanSay(std::string_view aText)
{
    std::string text(aText);
    std::replace_if(text.begin(), text.end(), [](char c) { return c == '\t' || c == '\r' || c == '\n'; }, ' ');
    static const std::regex stageDirections(R"(\*[^*]{1,60}\*)");
    static const std::regex spaces(R"(\s{2,})");
    text = std::regex_replace(text, stageDirections, "");
    text = std::regex_replace(text, spaces, " ");
    return Trim(text);
}

std::optional<std::string> ReadFile(const std::filesystem::path& aFile)
{
    std::ifstream in(aFile, std::ios::binary);
    if (!in)
        return std::nullopt;
    std::ostringstream content;
    content << in.rdbuf();
    std::string text = content.str();
    // A UTF-8 BOM is not part of the text.
    if (text.rfind("\xEF\xBB\xBF", 0) == 0)
        text.erase(0, 3);
    return text;
}
} // namespace apiko::text
