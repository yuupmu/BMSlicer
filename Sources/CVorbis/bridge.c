#include <stdlib.h>
#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"
#include "include/CVorbis.h"
int bms_decode_vorbis(const char *path, float **samples, int *channels, int *rate, int *frames) {
    int error = 0;
    stb_vorbis *v = stb_vorbis_open_filename(path, &error, NULL);
    if (!v) return error ? error : -1;
    stb_vorbis_info info = stb_vorbis_get_info(v);
    unsigned int count = stb_vorbis_stream_length_in_samples(v);
    if (!count || !info.channels || (double)count * info.channels > 134217728.0) { stb_vorbis_close(v); return -2; }
    float *data = malloc((size_t)count * info.channels * sizeof(float));
    if (!data) { stb_vorbis_close(v); return -3; }
    int total = 0;
    while (total < count) {
        int got = stb_vorbis_get_samples_float_interleaved(v, info.channels, data + (size_t)total * info.channels, (count-total)*info.channels);
        if (got <= 0) break;
        total += got;
    }
    int final_error = stb_vorbis_get_error(v);
    stb_vorbis_close(v);
    if (final_error || total != count) { free(data); return -4; }
    *samples = data; *channels = info.channels; *rate = info.sample_rate; *frames = total;
    return 0;
}
void bms_free(void *ptr) { free(ptr); }
