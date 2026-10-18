#import "JFPlaybackTrace.h"
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>

void JFPlaybackTrace(NSString *event) {
    if (![event isKindOfClass:[NSString class]] || !event.length || event.length>256) return;
    if ([event rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location!=NSNotFound) return;

    static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
    NSTimeInterval uptime=[NSProcessInfo processInfo].systemUptime;
    NSString *line=[NSString stringWithFormat:@"T=%llu %@\n",
                    (unsigned long long)MAX(0.0,uptime*1000.0),event];
    NSData *data=[line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;

    pthread_mutex_lock(&lock);
    int fd=open("/tmp/Jellyfin-ATV3.playbacktrace",O_WRONLY|O_CREAT|O_APPEND,0600);
    if (fd>=0) {
        (void)write(fd,data.bytes,data.length);
        (void)close(fd);
    }
    pthread_mutex_unlock(&lock);
}
