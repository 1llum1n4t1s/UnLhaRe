#include <unlhare.h>

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void print_last_error(void)
{
    uint64_t required = 0;
    int32_t status = unlhare_last_error(NULL, 0, &required);
    if (status != UNLHARE_STATUS_BUFFER_TOO_SMALL || required == 0) {
        fputs("unlhare operation failed (no error details available)\n", stderr);
        return;
    }

    char *message = (char *)malloc((size_t)required);
    if (message == NULL) {
        fputs("unlhare operation failed (could not allocate the error buffer)\n", stderr);
        return;
    }

    status = unlhare_last_error(message, required, &required);
    if (status == UNLHARE_STATUS_OK) {
        fprintf(stderr, "unlhare operation failed: %s\n", message);
    } else {
        fprintf(stderr, "unlhare operation failed while reading error details (status %" PRId32 ")\n", status);
    }
    free(message);
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <archive.lzh>\n", argv[0]);
        return EXIT_FAILURE;
    }

    uint32_t abi_version = unlhare_abi_version();
    if (abi_version != UNLHARE_ABI_VERSION) {
        fprintf(stderr,
                "unsupported unlhare ABI version: expected %" PRIu32 ", got %" PRIu32 "\n",
                UNLHARE_ABI_VERSION,
                abi_version);
        return EXIT_FAILURE;
    }
    printf("unlhare ABI version: %" PRIu32 "\n", abi_version);

    uint64_t required = 0;
    int32_t status = unlhare_list_json(argv[1], NULL, 0, &required);
    if (status != UNLHARE_STATUS_BUFFER_TOO_SMALL || required == 0) {
        fprintf(stderr, "could not determine the JSON buffer size (status %" PRId32 ")\n", status);
        print_last_error();
        return EXIT_FAILURE;
    }

    char *json = (char *)malloc((size_t)required);
    if (json == NULL) {
        fprintf(stderr, "could not allocate %" PRIu64 " bytes for the JSON result\n", required);
        return EXIT_FAILURE;
    }

    status = unlhare_list_json(argv[1], json, required, &required);
    if (status != UNLHARE_STATUS_OK) {
        fprintf(stderr, "could not list the archive (status %" PRId32 ")\n", status);
        print_last_error();
        free(json);
        return EXIT_FAILURE;
    }

    puts(json);
    free(json);
    return EXIT_SUCCESS;
}
