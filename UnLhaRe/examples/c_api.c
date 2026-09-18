#include <unlhare.h>

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void print_json(void *user, const char *json, uint64_t length)
{
    int *write_failed = (int *)user;
    if (fwrite(json, 1, (size_t)length, stdout) != (size_t)length || putchar('\n') == EOF) {
        *write_failed = 1;
    }
}

static int32_t print_entry_json(void *user, const char *json, uint64_t length)
{
    print_json(user, json, length);
    return *(int *)user != 0;
}

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
    int list_json = argc == 3 && strcmp(argv[1], "--list-json") == 0;
    int list_entries = argc == 3 && strcmp(argv[1], "--list-entries") == 0;
    if (argc != 2 && !list_json && !list_entries) {
        fprintf(stderr,
                "Usage: %s <archive.lzh> | --list-json <request-json> | --list-entries <request-json>\n",
                argv[0]);
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

    if (argc == 3) {
        uint32_t required_level = list_entries ? 5 : 3;
        if (unlhare_api_level() < required_level) {
            fprintf(stderr, "%s requires API level %" PRIu32 "\n", argv[1], required_level);
            return EXIT_FAILURE;
        }
        int write_failed = 0;
        int32_t status = list_entries
            ? unlhare_list_entries_json(argv[2], NULL, print_entry_json, &write_failed)
            : unlhare_list_json_with_progress(argv[2], NULL, print_json, &write_failed);
        if (status != UNLHARE_STATUS_OK) {
            print_last_error();
        }
        return status == UNLHARE_STATUS_OK && !write_failed ? EXIT_SUCCESS : EXIT_FAILURE;
    }

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
