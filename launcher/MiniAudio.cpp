// miniaudio's implementation (deps\miniaudio\miniaudio.h, public domain or MIT-0), in its own unit: only devices are
// used (playback now, capture for push-to-talk later), so decoding, encoding and the engine are left out. Its own
// warnings are not ours.
#pragma warning(push, 0)
#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#include <miniaudio/miniaudio.h>
#pragma warning(pop)
