/*
 * CUPS backend: spool the job only. fichero-rfcomm sends it over RFCOMM.
 * Do not write to /dev/cu.FICHERO* from cupsd — open() can hang in D-state.
 *
 * URI: fichero-serial:FICHERO_6181  (Bluetooth name, or "rfcomm" for first match)
 */

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define BACKEND "fichero-serial"
#define SPOOL "/var/spool/cups/tmp/fichero"

enum { OK = 0, FAILED = 1, RETRY = 6 };

static void
logmsg(const char *kind, const char *msg)
{
    fprintf(stderr, "%s: %s\n", kind, msg);
    fflush(stderr);
}

static int
discover(void)
{
    /* Do not advertise devices. install.sh creates the queues; if this
     * backend prints a "direct ..." line, macOS printtool auto-adds a
     * second printer named after the info string (Bluetooth RFCOMM). */
    return OK;
}

static int
write_file(const char *path, const unsigned char *data, size_t len)
{
    FILE *fp = fopen(path, "wb");
    if (fp == NULL)
        return -1;
    if (len > 0 && fwrite(data, 1, len, fp) != len) {
        fclose(fp);
        return -1;
    }
    if (fclose(fp) != 0)
        return -1;
    return 0;
}

static void
device_hint(char *out, size_t n)
{
    const char *uri = getenv("DEVICE_URI");
    const char *p;

    out[0] = '\0';
    if (uri == NULL)
        return;
    p = strrchr(uri, ':');
    if (p == NULL)
        return;
    p++;
    while (*p == '/')
        p++;
    if (strncmp(p, "name=", 5) == 0)
        p += 5;
    if (p[0] == '\0' || strcmp(p, "rfcomm") == 0)
        return;
    snprintf(out, n, "%s", p);
}

static unsigned char *
read_job(int argc, char **argv, size_t *out_len)
{
    FILE *fp;
    unsigned char *data = NULL;
    size_t cap = 0, len = 0;
    unsigned char buf[8192];
    size_t n;

    if (argc >= 7 && argv[6][0] && strcmp(argv[6], "-") != 0)
        fp = fopen(argv[6], "rb");
    else
        fp = stdin;
    if (fp == NULL)
        return NULL;

    while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) {
        if (len + n > cap) {
            size_t ncap = cap ? cap * 2 : 65536;
            unsigned char *tmp;
            while (ncap < len + n)
                ncap *= 2;
            tmp = realloc(data, ncap);
            if (tmp == NULL) {
                free(data);
                if (fp != stdin)
                    fclose(fp);
                return NULL;
            }
            data = tmp;
            cap = ncap;
        }
        memcpy(data + len, buf, n);
        len += n;
    }
    if (fp != stdin)
        fclose(fp);
    *out_len = len;
    return data;
}

static int
run_job(int argc, char **argv)
{
    const char *job = (argc >= 2) ? argv[1] : "unknown";
    unsigned char *data;
    size_t len = 0;
    char data_path[512], ready_path[512], status_path[512], device_path[512];
    char hint[256], buf[256];
    int i;

    mkdir(SPOOL, 0777);

    logmsg("STATE", "-connecting-to-device");
    snprintf(buf, sizeof(buf), "Spooling job %s", job);
    logmsg("INFO", buf);

    data = read_job(argc, argv, &len);
    if (data == NULL || len == 0) {
        logmsg("ERROR", "Empty print job");
        free(data);
        return FAILED;
    }

    snprintf(data_path, sizeof(data_path), "%s/%s.data", SPOOL, job);
    snprintf(ready_path, sizeof(ready_path), "%s/%s.ready", SPOOL, job);
    snprintf(status_path, sizeof(status_path), "%s/%s.status", SPOOL, job);
    snprintf(device_path, sizeof(device_path), "%s/%s.device", SPOOL, job);
    unlink(status_path);
    unlink(device_path);

    device_hint(hint, sizeof(hint));
    if (hint[0]) {
        snprintf(buf, sizeof(buf), "Target Bluetooth name %s", hint);
        logmsg("INFO", buf);
        if (write_file(device_path, (const unsigned char *)hint, strlen(hint)) != 0) {
            logmsg("ERROR", "Cannot write spool device hint");
            free(data);
            return FAILED;
        }
    }

    if (write_file(data_path, data, len) != 0) {
        snprintf(buf, sizeof(buf), "Cannot write spool data (%s): %s", data_path,
                 strerror(errno));
        logmsg("ERROR", buf);
        free(data);
        return FAILED;
    }
    free(data);
    if (write_file(ready_path, (const unsigned char *)"", 0) != 0) {
        logmsg("ERROR", "Cannot write spool ready");
        return FAILED;
    }

    for (i = 0; i < 1800; i++) {
        FILE *fp = fopen(status_path, "r");
        if (fp != NULL) {
            char line[256];
            if (fgets(line, sizeof(line), fp) == NULL)
                line[0] = '\0';
            fclose(fp);
            unlink(status_path);
            unlink(data_path);
            unlink(ready_path);
            unlink(device_path);
            if (strncmp(line, "OK", 2) == 0) {
                logmsg("INFO", "RFCOMM send complete");
                logmsg("STATE", "-offline");
                return OK;
            }
            snprintf(buf, sizeof(buf), "RFCOMM helper: %s", line);
            logmsg("ERROR", buf);
            return RETRY;
        }
        usleep(100000);
    }

    logmsg("ERROR", "Timeout waiting for fichero-rfcomm LaunchDaemon");
    logmsg("STATE", "+offline");
    return RETRY;
}

int
main(int argc, char **argv)
{
    if (argc == 1)
        return discover();
    if (argc != 6 && argc != 7) {
        logmsg("ERROR", BACKEND " job args: job-id user title copies options [file]");
        return FAILED;
    }
    return run_job(argc, argv);
}
