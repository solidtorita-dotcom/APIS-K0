// Native Piper on one text, to compare by ear with the Python bridge's (piper1-gpl).
// Usage: piper_wav <espeak-ng-data> <voices folder> <voice[#speaker]> <speed> <out.wav> <text (UTF-8)>
// onnxruntime.dll is loaded from next to this program.
#include "../Piper.hpp"

#include <Windows.h>

#include <cstdint>
#include <fstream>
#include <iostream>
#include <string>

namespace
{
std::string Utf8(const wchar_t* aText)
{
    int size = WideCharToMultiByte(CP_UTF8, 0, aText, -1, nullptr, 0, nullptr, nullptr);
    std::string out(size > 0 ? size - 1 : 0, '\0');
    WideCharToMultiByte(CP_UTF8, 0, aText, -1, out.data(), size, nullptr, nullptr);
    return out;
}
} // namespace

int wmain(int argc, wchar_t** argv)
{
    if (argc < 7)
    {
        std::cerr << "usage: piper_wav <espeak-ng-data> <voices> <voice> <speed> <out.wav> <text>\n";
        return 2;
    }
    wchar_t exe[MAX_PATH];
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    apiko::piper::Piper piper(std::filesystem::path(exe).parent_path() / L"onnxruntime.dll", argv[1], argv[2]);
    try
    {
        SetConsoleOutputCP(CP_UTF8);
        std::string voice = Utf8(argv[3]);
        std::cout << piper.PhonemeText(Utf8(argv[6]), voice.rfind("es_", 0) == 0 ? "es" : "en-us");
        int rate = 0;
        auto started = GetTickCount64();
        auto audio = piper.Synthesize(Utf8(argv[6]), Utf8(argv[3]), _wtof(argv[4]), rate);
        std::cout << "first call " << GetTickCount64() - started << " ms (loads the model)\n";
        started = GetTickCount64();
        audio = piper.Synthesize(Utf8(argv[6]), Utf8(argv[3]), _wtof(argv[4]), rate);
        std::cout << "second call " << GetTickCount64() - started << " ms for " << audio.size() / double(rate) << " s\n";
        std::ofstream file(argv[5], std::ios::binary);
        auto put32 = [&](std::uint32_t v) { file.write(reinterpret_cast<const char*>(&v), 4); };
        auto put16 = [&](std::uint16_t v) { file.write(reinterpret_cast<const char*>(&v), 2); };
        auto bytes = static_cast<std::uint32_t>(audio.size() * 2);
        file.write("RIFF", 4);
        put32(36 + bytes);
        file.write("WAVEfmt ", 8);
        put32(16);
        put16(1);
        put16(1);
        put32(rate);
        put32(rate * 2);
        put16(2);
        put16(16);
        file.write("data", 4);
        put32(bytes);
        for (float v : audio)
            put16(static_cast<std::uint16_t>(static_cast<std::int16_t>(v * 32767)));
    }
    catch (const std::exception& e)
    {
        std::cerr << "error: " << e.what() << "\n";
        return 1;
    }
    return 0;
}
