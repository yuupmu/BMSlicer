#ifndef CVORBIS_H
#define CVORBIS_H
int bms_decode_vorbis(const char *path, float **samples, int *channels, int *rate, int *frames);
void bms_free(void *ptr);
#endif
int bms_decode_mp3(const char *path, float **samples, int *channels, int *rate, int *frames);
