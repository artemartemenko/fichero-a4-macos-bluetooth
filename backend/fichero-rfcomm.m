/*
 * Send a print job over Classic Bluetooth RFCOMM (SPP).
 * /dev/cu.FICHERO* on macOS can hang open() in D-state, so CUPS must not use it.
 */

#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static NSString *const kSpoolDir = @"/var/spool/cups/tmp/fichero";

@interface RFCommSender : NSObject <IOBluetoothRFCOMMChannelDelegate>
@property (assign) BOOL openDone;
@property (assign) IOReturn openStatus;
@property (assign) BOOL writeDone;
@property (assign) IOReturn writeStatus;
@end

@implementation RFCommSender
- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)channel status:(IOReturn)error
{
    (void)channel;
    self.openStatus = error;
    self.openDone = YES;
}
- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)channel data:(void *)dataPointer length:(size_t)dataLength
{
    (void)channel;
    (void)dataPointer;
    (void)dataLength;
}
- (void)rfcommChannelWriteComplete:(IOBluetoothRFCOMMChannel *)channel refcon:(void *)refcon status:(IOReturn)error
{
    (void)channel;
    (void)refcon;
    self.writeStatus = error;
    self.writeDone = YES;
}
- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)channel
{
    (void)channel;
}
@end

static BOOL
run_until(BOOL (^pred)(void), NSTimeInterval seconds)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!pred() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return pred();
}

static NSString *
norm_name(NSString *s)
{
    NSString *u = s.uppercaseString;
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < u.length; i++) {
        unichar c = [u characterAtIndex:i];
        if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:c])
            [out appendFormat:@"%C", c];
    }
    return out;
}

static BOOL
is_fichero_family(NSString *name)
{
    NSString *n = name.uppercaseString;
    return [n hasPrefix:@"FICHERO"] || [n hasPrefix:@"CRAFTS"] ||
           [n containsString:@"5622"] || [n containsString:@"6897"] ||
           [n containsString:@"6181"];
}

static NSString *
model_code(NSString *s)
{
    NSString *u = s.uppercaseString;
    for (NSString *code in @[ @"6181", @"5622", @"6897" ]) {
        if ([u containsString:code])
            return code;
    }
    return nil;
}

static BOOL
name_matches(NSString *have, NSString *want)
{
    if (want.length == 0)
        return YES;
    NSString *haveCode = model_code(have);
    NSString *wantCode = model_code(want);
    if (haveCode && wantCode && ![haveCode isEqualToString:wantCode])
        return NO;
    NSString *a = have.uppercaseString;
    NSString *b = want.uppercaseString;
    if ([a isEqualToString:b])
        return YES;
    if ([a containsString:b] || [b containsString:a])
        return YES;
    NSString *na = norm_name(have);
    NSString *nb = norm_name(want);
    if (na.length && nb.length && ([na isEqualToString:nb] || [na containsString:nb] || [nb containsString:na]))
        return YES;
    return NO;
}

static IOBluetoothDevice *
find_printer(NSString *wantName)
{
    NSArray *paired = [IOBluetoothDevice pairedDevices];
    IOBluetoothDevice *fallback = nil;
    for (IOBluetoothDevice *dev in paired) {
        NSString *name = dev.name ?: @"";
        if (!is_fichero_family(name))
            continue;
        if (wantName.length && name_matches(name, wantName))
            return dev;
        if (fallback == nil)
            fallback = dev;
    }
    if (wantName.length)
        return nil;
    return fallback;
}

static int
send_bytes(NSData *payload, NSString *wantName)
{
    IOBluetoothDevice *dev = find_printer(wantName);
    if (!dev) {
        if (wantName.length)
            fprintf(stderr, "ERROR: No paired printer matching '%s'\n", wantName.UTF8String);
        else
            fprintf(stderr, "ERROR: No paired FICHERO Bluetooth printer\n");
        NSArray *paired = [IOBluetoothDevice pairedDevices];
        fprintf(stderr, "INFO: paired count=%lu\n", (unsigned long)paired.count);
        for (IOBluetoothDevice *d in paired) {
            fprintf(stderr, "INFO: paired name='%s'\n", d.name.UTF8String ?: "");
        }
        return 1;
    }
    fprintf(stderr, "INFO: Using device %s addr=%s connected=%d\n",
            dev.name.UTF8String ?: "?",
            dev.addressString.UTF8String ?: "?",
            (int)dev.isConnected);

    if (dev.isConnected) {
        fprintf(stderr, "INFO: Closing existing baseband so SPP TTY releases RFCOMM\n");
        [dev closeConnection];
        run_until(^BOOL { return !dev.isConnected; }, 4.0);
        usleep(300000);
    }

    IOReturn cr = [dev openConnection];
    if (cr != kIOReturnSuccess) {
        fprintf(stderr, "ERROR: openConnection failed: %d\n", cr);
        return 1;
    }
    if (!run_until(^BOOL { return dev.isConnected; }, 8.0)) {
        fprintf(stderr, "ERROR: connect timeout\n");
        return 1;
    }

    RFCommSender *delegate = [RFCommSender new];
    IOBluetoothRFCOMMChannel *channel = nil;
    BluetoothRFCOMMChannelID channelID = 1;
    IOReturn r = [dev openRFCOMMChannelSync:&channel withChannelID:channelID delegate:delegate];
    if (r != kIOReturnSuccess || channel == nil) {
        fprintf(stderr, "ERROR: openRFCOMMChannelSync failed: %d\n", r);
        return 1;
    }
    if (!delegate.openDone) {
        run_until(^BOOL { return delegate.openDone; }, 8.0);
    }
    if (delegate.openDone && delegate.openStatus != kIOReturnSuccess) {
        fprintf(stderr, "ERROR: RFCOMM open status %d\n", delegate.openStatus);
        [channel closeChannel];
        return 1;
    }

    const uint8_t *bytes = payload.bytes;
    NSUInteger len = payload.length;
    NSUInteger off = 0;
    const NSUInteger chunk = 1024;
    while (off < len) {
        NSUInteger n = MIN(chunk, len - off);
        uint8_t buf[1024];
        memcpy(buf, bytes + off, n);
        r = [channel writeSync:buf length:(UInt16)n];
        if (r != kIOReturnSuccess) {
            fprintf(stderr, "ERROR: writeSync failed at %lu: %d\n", (unsigned long)off, r);
            [channel closeChannel];
            return 1;
        }
        off += n;
        usleep(1500);
        if ((off / 16384) != ((off - n) / 16384))
            fprintf(stderr, "INFO: sent %lu / %lu\n", (unsigned long)off, (unsigned long)len);
    }

    usleep(200000);
    [channel closeChannel];
    fprintf(stderr, "INFO: RFCOMM send complete (%lu bytes)\n", (unsigned long)len);
    return 0;
}

static void
write_status(NSString *job, NSString *text)
{
    NSString *path = [kSpoolDir stringByAppendingPathComponent:[job stringByAppendingString:@".status"]];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSString *
read_device_hint(NSString *job)
{
    NSString *path = [kSpoolDir stringByAppendingPathComponent:[job stringByAppendingString:@".device"]];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static int
drain_spool(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:kSpoolDir error:nil];
    int rc = 0;
    for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
        if (![name hasSuffix:@".ready"])
            continue;
        NSString *job = [name stringByDeletingPathExtension];
        NSString *dataPath = [kSpoolDir stringByAppendingPathComponent:[job stringByAppendingString:@".data"]];
        NSString *readyPath = [kSpoolDir stringByAppendingPathComponent:name];
        NSString *devicePath = [kSpoolDir stringByAppendingPathComponent:[job stringByAppendingString:@".device"]];
        NSData *payload = [NSData dataWithContentsOfFile:dataPath];
        if (!payload.length) {
            write_status(job, @"ERROR empty job\n");
            [fm removeItemAtPath:readyPath error:nil];
            rc = 1;
            continue;
        }
        NSString *want = read_device_hint(job);
        fprintf(stderr, "INFO: draining job %s (%lu bytes) name=%s\n",
                job.UTF8String, (unsigned long)payload.length, want.UTF8String ?: "-");
        int send_rc = send_bytes(payload, want);
        write_status(job, send_rc == 0 ? @"OK\n" : @"ERROR send failed\n");
        [fm removeItemAtPath:readyPath error:nil];
        [fm removeItemAtPath:dataPath error:nil];
        [fm removeItemAtPath:devicePath error:nil];
        if (send_rc != 0)
            rc = send_rc;
    }
    return rc;
}

static int
parse_args(int argc, const char *argv[], NSString **filePath, NSString **wantName)
{
    *filePath = nil;
    *wantName = nil;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--file") == 0 && i + 1 < argc) {
            *filePath = @(argv[++i]);
        } else if (strcmp(argv[i], "--name") == 0 && i + 1 < argc) {
            *wantName = @(argv[++i]);
        } else {
            return 2;
        }
    }
    return (*filePath != nil) ? 0 : 2;
}

int
main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc >= 2 && strcmp(argv[1], "--drain") == 0)
            return drain_spool();
        NSString *filePath = nil;
        NSString *wantName = nil;
        if (parse_args(argc, argv, &filePath, &wantName) != 0) {
            fprintf(stderr, "Usage: fichero-rfcomm --drain | --file PATH [--name NAME]\n");
            return 2;
        }
        NSData *payload = [NSData dataWithContentsOfFile:filePath];
        if (!payload) {
            fprintf(stderr, "ERROR: cannot read %s\n", filePath.UTF8String);
            return 1;
        }
        return send_bytes(payload, wantName);
    }
}
