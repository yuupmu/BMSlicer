#define MINIMP3_IMPLEMENTATION
#define MINIMP3_FLOAT_OUTPUT
#include "minimp3_ex.h"
#include "include/CVorbis.h"
int bms_decode_mp3(const char *path, float **samples, int *channels, int *rate, int *frames) {
    mp3dec_ex_t dec;
    int result = mp3dec_ex_open(&dec, path, MP3D_SEEK_TO_SAMPLE);
    if (result) return result;
    if (!dec.samples || !dec.info.channels || dec.samples > 134217728) { mp3dec_ex_close(&dec); return -2; }
    float *data = malloc((size_t)dec.samples * sizeof(float));
    if (!data) { mp3dec_ex_close(&dec); return -3; }
    size_t got = mp3dec_ex_read(&dec, data, dec.samples);
    if (!got || dec.last_error) { free(data); mp3dec_ex_close(&dec); return -4; }
    *samples = data; *channels = dec.info.channels; *rate = dec.info.hz; *frames = (int)(got/dec.info.channels);
    mp3dec_ex_close(&dec);
    return 0;
}
