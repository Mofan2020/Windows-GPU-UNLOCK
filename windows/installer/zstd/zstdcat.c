/*
 * zstdcat - extract one member from a zstd compressed tar stream.
 *
 * Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
 *
 * Why this exists
 * ---------------
 * The Windows installer has to read the pinned nvidia-utils package, which is
 * distributed as a .pkg.tar.zst archive. The tar.exe that ships with Windows
 * is bsdtar 3.3.2, built on libarchive 3.3.2, which has no zstd support at
 * all: the zstd filter was only added to libarchive in 3.3.3. The archive
 * also cannot be unpacked through the "external program" filter, because
 * Windows has no zstd binary. On Windows 11 the bundled bsdtar is newer and
 * does read zstd, but relying on that would leave Windows 10 without a
 * working installer.
 *
 * So the installer ships this helper. It decompresses the zstd stream that
 * is fed into its standard input, walks the tar headers, and writes the
 * requested member to an output file. It stops as soon as that member is
 * complete, which lets the caller abandon the download: the member we need
 * is the thirtieth entry of the package, so only about 73 MiB of the 300 MiB
 * compressed package has to be transferred.
 *
 * The decompression itself is the Zstandard reference implementation, vendored
 * under lib/ from facebook/zstd. That code is under the BSD 3-Clause licence,
 * see LICENSE.
 *
 * Usage
 * -----
 *   zstdcat --member <name> --output <file>   read a zstd tar stream from
 *                                             stdin and write <name> to <file>
 *   zstdcat                                   decompress stdin to stdout
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ZSTD_STATIC_LINKING_ONLY
#include "lib/zstd.h"

#define TAR_BLOCK 512

/*
 * A tar stream reader on top of the decompressor. The decompressed bytes are
 * handed out in the order they are produced, so the caller sees a plain byte
 * stream of the tar archive.
 */
struct reader {
    ZSTD_DStream *stream;
    char *compressed;
    size_t compressed_size;
    ZSTD_inBuffer input;
    char *plain;
    size_t plain_size;
    size_t plain_pos;
    size_t plain_len;
    int input_done;
};

static int reader_init(struct reader *reader)
{
    memset(reader, 0, sizeof(*reader));
    reader->stream = ZSTD_createDStream();
    if (reader->stream == NULL)
        return -1;
    reader->compressed_size = ZSTD_DStreamInSize();
    reader->plain_size = ZSTD_DStreamOutSize();
    reader->compressed = (char *)malloc(reader->compressed_size);
    reader->plain = (char *)malloc(reader->plain_size);
    if (reader->compressed == NULL || reader->plain == NULL)
        return -1;
    ZSTD_initDStream(reader->stream);
    return 0;
}

static void reader_free(struct reader *reader)
{
    if (reader->stream != NULL)
        ZSTD_freeDStream(reader->stream);
    free(reader->compressed);
    free(reader->plain);
    reader->stream = NULL;
    reader->compressed = NULL;
    reader->plain = NULL;
}

/* Fills the plain buffer with the next chunk of decompressed bytes. */
static int reader_refill(struct reader *reader)
{
    for (;;) {
        ZSTD_outBuffer output;
        size_t result;

        /* The decompressor may not consume the whole input in one call, so
         * the input position is kept between calls and only refilled once
         * everything has been used. */
        if (reader->input.pos == reader->input.size) {
            size_t got;
            if (reader->input_done)
                return -1;
            got = fread(reader->compressed, 1, reader->compressed_size, stdin);
            if (got == 0) {
                reader->input_done = 1;
                return -1;
            }
            reader->input.src = reader->compressed;
            reader->input.size = got;
            reader->input.pos = 0;
        }

        output.dst = reader->plain;
        output.size = reader->plain_size;
        output.pos = 0;
        result = ZSTD_decompressStream(reader->stream, &output, &reader->input);
        if (ZSTD_isError(result)) {
            fprintf(stderr, "zstdcat: %s\n", ZSTD_getErrorName(result));
            return -1;
        }
        if (output.pos > 0) {
            reader->plain_pos = 0;
            reader->plain_len = output.pos;
            return 0;
        }
        if (result == 0) {
            /* The frame ended. A following frame starts a new session. */
            ZSTD_initDStream(reader->stream);
        }
    }
}

/* Reads up to n bytes; returns the number of bytes actually read. */
static size_t reader_read(struct reader *reader, char *buffer, size_t n)
{
    size_t done = 0;

    while (done < n) {
        size_t available;
        if (reader->plain_pos >= reader->plain_len) {
            if (reader_refill(reader) != 0)
                break;
        }
        available = reader->plain_len - reader->plain_pos;
        if (available > n - done)
            available = n - done;
        memcpy(buffer + done, reader->plain + reader->plain_pos, available);
        reader->plain_pos += available;
        done += available;
    }
    return done;
}

/* Parses the octal size field of a tar header. */
static int parse_octal(const char *field, size_t length, unsigned long long *out)
{
    unsigned long long value = 0;
    size_t i = 0;
    int digits = 0;

    while (i < length && (field[i] == ' ' || field[i] == '\0'))
        i++;
    for (; i < length; i++) {
        char c = field[i];
        if (c == '\0' || c == ' ')
            break;
        if (c < '0' || c > '7')
            return -1;
        value = value * 8 + (unsigned long long)(c - '0');
        digits++;
    }
    if (digits == 0)
        return -1;
    *out = value;
    return 0;
}

/* Copies a NUL terminated field and strips trailing spaces. */
static void copy_field(char *dest, size_t dest_size, const char *field, size_t length)
{
    size_t i;

    for (i = 0; i < length && field[i] != '\0' && i + 1 < dest_size; i++)
        dest[i] = field[i];
    dest[i] = '\0';
    while (i > 0 && dest[i - 1] == ' ')
        dest[--i] = '\0';
}

int main(int argc, char **argv)
{
    const char *wanted = NULL;
    const char *output_path = NULL;
    int i;
    FILE *out = stdout;
    int written = 0;
    int status = 1;
    struct reader reader;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--member") == 0 && i + 1 < argc) {
            wanted = argv[++i];
        } else if (strcmp(argv[i], "--output") == 0 && i + 1 < argc) {
            output_path = argv[++i];
        } else if (strcmp(argv[i], "--version") == 0) {
            printf("zstdcat 1.0 (zstd %s)\n", ZSTD_versionString());
            return 0;
        } else if (strcmp(argv[i], "--help") == 0) {
            printf("usage: zstdcat --member <name> --output <file>\n");
            printf("       zstdcat --version\n");
            return 0;
        } else {
            fprintf(stderr, "zstdcat: unknown argument: %s\n", argv[i]);
            return 2;
        }
    }

    if (wanted != NULL && output_path == NULL) {
        fprintf(stderr, "zstdcat: --member requires --output\n");
        return 2;
    }
    if (wanted == NULL && output_path != NULL) {
        fprintf(stderr, "zstdcat: --output requires --member\n");
        return 2;
    }

    if (wanted != NULL) {
        out = fopen(output_path, "wb");
        if (out == NULL) {
            fprintf(stderr, "zstdcat: cannot open %s for writing\n", output_path);
            return 2;
        }
    }

    if (reader_init(&reader) != 0) {
        fprintf(stderr, "zstdcat: cannot start the decompression stream\n");
        goto cleanup;
    }

    /* The decompressed bytes are a tar stream: each member is a header
     * block, followed by the data and the padding to a block boundary. */
    for (;;) {
        char header[TAR_BLOCK];
        char name[256];
        char prefix[256];
        char full[520];
        unsigned long long size = 0;
        unsigned long long padding;
        char type;
        size_t got;
        int empty = 1;
        size_t k;

        got = reader_read(&reader, header, TAR_BLOCK);
        if (got == 0)
            break;
        if (got != TAR_BLOCK) {
            fprintf(stderr, "zstdcat: truncated tar header\n");
            break;
        }
        for (k = 0; k < TAR_BLOCK; k++) {
            if (header[k] != 0) {
                empty = 0;
                break;
            }
        }
        if (empty)
            break;

        copy_field(name, sizeof(name), header, 100);
        copy_field(prefix, sizeof(prefix), header + 345, 155);
        if (prefix[0] != '\0')
            snprintf(full, sizeof(full), "%s/%s", prefix, name);
        else
            snprintf(full, sizeof(full), "%s", name);
        type = header[156];
        if (parse_octal(header + 124, 12, &size) != 0) {
            fprintf(stderr, "zstdcat: malformed size field for %s\n", full);
            break;
        }
        padding = (size + TAR_BLOCK - 1) / TAR_BLOCK * TAR_BLOCK;

        /* GNU long names and POSIX extended headers carry the real name in
         * the data of the header entry. Handle them so the walk stays
         * correct for archives that use them. */
        if (type == 'L' || type == 'x' || type == 'g') {
            char *buffer;
            if (padding > (1u << 20)) {
                fprintf(stderr, "zstdcat: extended header is too large\n");
                break;
            }
            buffer = (char *)malloc((size_t)padding);
            if (buffer == NULL) {
                fprintf(stderr, "zstdcat: out of memory\n");
                break;
            }
            if (reader_read(&reader, buffer, (size_t)padding) != padding) {
                free(buffer);
                fprintf(stderr, "zstdcat: truncated extended header\n");
                break;
            }
            if (type == 'L') {
                size_t length = (size_t)size;
                if (length > 0 && buffer[length - 1] == '\0')
                    length--;
                if (length >= sizeof(name))
                    length = sizeof(name) - 1;
                memcpy(name, buffer, length);
                name[length] = '\0';
            } else {
                /* POSIX extended header: look for a path record. */
                char *record = buffer;
                unsigned long long left = size;
                int found = 0;
                while (left > 0 && !found) {
                    unsigned long long length = 0;
                    if (parse_octal(record, 12, &length) != 0 || length == 0)
                        break;
                    if (length > left)
                        break;
                    if (length > 17 && memcmp(record + 12, "path=", 5) == 0) {
                        size_t value_length = (size_t)length - 17;
                        if (value_length >= sizeof(name))
                            value_length = sizeof(name) - 1;
                        memcpy(name, record + 17, value_length);
                        name[value_length] = '\0';
                        found = 1;
                    }
                    record += length;
                    left -= length;
                }
            }
            free(buffer);
            if (prefix[0] != '\0')
                snprintf(full, sizeof(full), "%s/%s", prefix, name);
            else
                snprintf(full, sizeof(full), "%s", name);
            continue;
        }

        if (wanted != NULL && strcmp(full, wanted) == 0) {
            unsigned long long left = size;
            char buffer[65536];
            while (left > 0) {
                size_t want = left < sizeof(buffer) ? (size_t)left : sizeof(buffer);
                if (reader_read(&reader, buffer, want) != want) {
                    fprintf(stderr, "zstdcat: truncated member %s\n", full);
                    goto cleanup;
                }
                if (fwrite(buffer, 1, want, out) != want) {
                    fprintf(stderr, "zstdcat: cannot write the output file\n");
                    goto cleanup;
                }
                left -= want;
            }
            fprintf(stderr, "zstdcat: extracted %s (%llu bytes)\n", full, size);
            written = 1;
            status = 0;
            goto cleanup;
        }

        /* Skip the member data and its padding. */
        {
            unsigned long long left = padding;
            char buffer[65536];
            while (left > 0) {
                size_t want = left < sizeof(buffer) ? (size_t)left : sizeof(buffer);
                if (reader_read(&reader, buffer, want) != want) {
                    fprintf(stderr, "zstdcat: truncated member %s\n", full);
                    goto cleanup;
                }
                left -= want;
            }
        }
    }

cleanup:
    reader_free(&reader);
    if (out != stdout) {
        if (fclose(out) != 0 && status == 0) {
            fprintf(stderr, "zstdcat: cannot close the output file\n");
            status = 1;
        }
    } else {
        fflush(stdout);
    }
    if (wanted != NULL && !written)
        status = 1;
    return status;
}
