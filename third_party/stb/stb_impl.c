/* The one place stb_image's implementation is compiled. Only JPEG is needed:
   PDF stores other image types as raw samples behind its own filters. */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#include "stb_image.h"
