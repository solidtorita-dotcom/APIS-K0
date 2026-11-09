// Speech recognition outside the game: a WAV through Ears::Transcribe with the player's settings, a second of
// silence, and the name fixes. Usage: ears_test <mod folder copy> <speech.wav>
#include "../Ears.hpp"
#include "../Log.hpp"
#include "../Providers.hpp"
#include "../Voice.hpp"

#include <Windows.h>

#include <iostream>

int wmain(int argc, wchar_t** argv)
{
    SetConsoleOutputCP(CP_UTF8);
    for (const char* sample : {"Oye a pico, ¿qué ves?", "Apíkó, ven.", "happy ko dime", "una pico no", "A-piko sí",
                               "Apiku y Abiko", "nada que cambiar"})
        std::cout << "FixName: " << sample << " -> " << apiko::ears::FixName(sample) << "\n";
    if (argc < 3)
        return 0;
    apiko::providers::Settings settings(argv[1]);
    settings.Check([](const std::string& aLine) { std::cout << aLine << "\n"; });
    std::mutex settingsMutex;
    nlohmann::json config = {{"whisper_hint", "Apiko, V, Night City, NetWatch, choom."}, {"stt_timeout_seconds", 8}};
    apiko::ears::Ears ears(settings, settingsMutex, config);
    auto speech = apiko::voice::LoadWav(argv[2]); // at 24 kHz
    if (!speech)
    {
        std::cerr << "cannot read the WAV\n";
        return 1;
    }
    std::vector<float> clip;
    for (double at = 0; at < speech->size(); at += 24000.0 / apiko::ears::MicRate)
        clip.push_back((*speech)[static_cast<std::size_t>(at)]);
    try
    {
        auto started = GetTickCount64();
        auto heard = ears.Transcribe(clip);
        std::cout << "speech: " << (heard ? heard->second + ": " + heard->first : std::string("(nothing)")) << " in "
                  << (GetTickCount64() - started) << " ms\n";
        auto silent = ears.Transcribe(std::vector<float>(apiko::ears::MicRate, 0.0f));
        std::cout << "silence: " << (silent ? silent->first : std::string("(nothing, as expected)")) << "\n";
        ears.Test();
        std::cout << "test: ok\n";
    }
    catch (const std::exception& e)
    {
        std::cout << "error: " << e.what() << "\n";
    }
    return 0;
}
