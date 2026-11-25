#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <inttypes.h>
#include <net/if.h>
#include <net/if_media.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sysexits.h>
#include <time.h>
#include <unistd.h>

static CFTypeRef property(io_service_t device, CFStringRef key)
{
    return IORegistryEntryCreateCFProperty(device, key, kCFAllocatorDefault, 0);
}

static int number_property(io_service_t device, CFStringRef key)
{
    CFTypeRef value = property(device, key);
    int number = -1;
    if (value != NULL) {
        if (CFGetTypeID(value) == CFNumberGetTypeID())
            CFNumberGetValue(value, kCFNumberIntType, &number);
        CFRelease(value);
    }
    return number;
}

static bool string_property(io_service_t device, CFStringRef key, char *out, size_t size)
{
    CFTypeRef value = property(device, key);
    if (value == NULL)
        return false;
    bool ok = CFGetTypeID(value) == CFStringGetTypeID() &&
        CFStringGetCString(value, out, (CFIndex)size, kCFStringEncodingUTF8);
    CFRelease(value);
    return ok;
}

static io_service_t find_module(bool *multiple)
{
    io_iterator_t devices = IO_OBJECT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &devices);
    if (result != KERN_SUCCESS)
        return IO_OBJECT_NULL;

    io_service_t target = IO_OBJECT_NULL;
    io_service_t device;
    while ((device = IOIteratorNext(devices)) != IO_OBJECT_NULL) {
        if (number_property(device, CFSTR("idVendor")) != 0x2ca3 ||
            number_property(device, CFSTR("idProduct")) != 0x4006) {
            IOObjectRelease(device);
            continue;
        }
        if (target != IO_OBJECT_NULL) {
            IOObjectRelease(device);
            IOObjectRelease(target);
            target = IO_OBJECT_NULL;
            *multiple = true;
            break;
        }
        target = device;
    }
    IOObjectRelease(devices);
    return target;
}

static bool ecm_interface(io_service_t module, char name[IFNAMSIZ])
{
    io_iterator_t children;
    if (IORegistryEntryGetChildIterator(module, kIOServicePlane, &children) != KERN_SUCCESS)
        return false;

    bool has_ecm = false;
    io_service_t child;
    while ((child = IOIteratorNext(children)) != IO_OBJECT_NULL) {
        if (IOObjectConformsTo(child, "IOUSBHostInterface") &&
            number_property(child, CFSTR("bInterfaceClass")) == 2 &&
            number_property(child, CFSTR("bInterfaceSubClass")) == 6) {
            has_ecm = true;
            io_iterator_t subtree;
            if (IORegistryEntryCreateIterator(child, kIOServicePlane, kIORegistryIterateRecursively,
                                              &subtree) == KERN_SUCCESS) {
                io_service_t node;
                while ((node = IOIteratorNext(subtree)) != IO_OBJECT_NULL) {
                    bool found = IOObjectConformsTo(node, "IOEthernetInterface") &&
                        string_property(node, CFSTR("BSD Name"), name, IFNAMSIZ);
                    IOObjectRelease(node);
                    if (found)
                        break;
                }
                IOObjectRelease(subtree);
            }
        }
        IOObjectRelease(child);
        if (has_ecm)
            break;
    }
    IOObjectRelease(children);
    return has_ecm;
}

static bool link_active(int fd, const char *name)
{
    struct ifmediareq request = {0};
    strlcpy(request.ifm_name, name, sizeof(request.ifm_name));
    return ioctl(fd, SIOCGIFMEDIA, &request) == 0 &&
        (request.ifm_status & (IFM_AVALID | IFM_ACTIVE)) == (IFM_AVALID | IFM_ACTIVE);
}

static void read_ipv4(const char *name, char address[INET_ADDRSTRLEN])
{
    struct ifaddrs *interfaces;
    if (getifaddrs(&interfaces) != 0)
        return;
    for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
        if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET || strcmp(item->ifa_name, name) != 0)
            continue;
        struct in_addr ip = ((struct sockaddr_in *)item->ifa_addr)->sin_addr;
        uint32_t host = ntohl(ip.s_addr);
        if ((host >> 24) == 0 || (host >> 24) == 127 || (host >> 16) == 0xa9fe || host == 0xc0000002)
            continue;
        inet_ntop(AF_INET, &ip, address, INET_ADDRSTRLEN);
        break;
    }
    freeifaddrs(interfaces);
}

static int watch(void)
{
    int media = socket(AF_INET, SOCK_DGRAM, 0);
    if (media < 0) {
        perror("status socket");
        return 1;
    }
    const struct timespec interval = {.tv_sec = 0, .tv_nsec = 500000000};
    for (;;) {
        bool multiple = false;
        io_service_t device = find_module(&multiple);
        uint64_t id = 0;
        char name[IFNAMSIZ] = "-";
        char ip[INET_ADDRSTRLEN] = "";
        bool ecm = false;
        const char *link = "missing";
        const char *status = multiple ? "multiple" : "absent";
        if (device != IO_OBJECT_NULL) {
            status = "module";
            IORegistryEntryGetRegistryEntryID(device, &id);
            ecm = ecm_interface(device, name);
            if (ecm && strcmp(name, "-") != 0) {
                link = link_active(media, name) ? "active" : "inactive";
                if (strcmp(link, "active") == 0)
                    read_ipv4(name, ip);
            }
            IOObjectRelease(device);
        }
        printf("%s|%s|%s|%s|%s|%" PRIx64 "|%jd\n", status, ecm ? "ecm" : "other", name,
               link, ip, id, (intmax_t)time(NULL));
        if (fflush(stdout) == EOF)
            break;
        nanosleep(&interval, NULL);
    }
    close(media);
    return 0;
}

static int lid(void)
{
    io_service_t root = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    CFTypeRef value = root == IO_OBJECT_NULL ? NULL : property(root, CFSTR("AppleClamshellState"));
    if (root != IO_OBJECT_NULL)
        IOObjectRelease(root);
    if (value != NULL && CFGetTypeID(value) == CFBooleanGetTypeID())
        puts(CFBooleanGetValue(value) ? "closed" : "open");
    else
        puts("unknown");
    if (value != NULL)
        CFRelease(value);
    return 0;
}

static int reenumerate(io_service_t device)
{
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(
        device, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (result != kIOReturnSuccess || plugin == NULL) {
        fprintf(stderr, "IOCreatePlugInInterfaceForService: 0x%08x\n", (unsigned)result);
        return 1;
    }
    IOUSBDeviceInterface500 **usb = NULL;
    HRESULT query = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID500), (LPVOID *)&usb);
    IODestroyPlugInInterface(plugin);
    if (query != S_OK || usb == NULL) {
        fprintf(stderr, "QueryInterface: 0x%08x\n", (unsigned)query);
        return 1;
    }
    result = (*usb)->USBDeviceOpen(usb);
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "USBDeviceOpen: 0x%08x\n", (unsigned)result);
        (*usb)->Release(usb);
        return result == kIOReturnExclusiveAccess ? EX_TEMPFAIL : 1;
    }
    result = (*usb)->USBDeviceReEnumerate(usb, 0);
    fprintf(stderr, "USBDeviceReEnumerate: 0x%08x\n", (unsigned)result);
    (*usb)->USBDeviceClose(usb);
    (*usb)->Release(usb);
    return result != kIOReturnSuccess;
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "lid") == 0)
        return lid();
    if (argc == 2 && strcmp(argv[1], "watch") == 0)
        return watch();

    bool inspect = argc == 2 && strcmp(argv[1], "inspect") == 0;
    bool reset = argc == 3 && strcmp(argv[1], "reenumerate") == 0;
    if (!inspect && !reset) {
        fputs("Usage: device inspect | lid | watch | reenumerate REGISTRY_ID\n", stderr);
        return 2;
    }

    bool multiple = false;
    io_service_t device = find_module(&multiple);
    if (device == IO_OBJECT_NULL) {
        puts(multiple ? "multiple" : "absent");
        return reset ? 1 : 0;
    }

    uint64_t id;
    if (IORegistryEntryGetRegistryEntryID(device, &id) != KERN_SUCCESS) {
        IOObjectRelease(device);
        return 1;
    }
    char registry_id[24];
    snprintf(registry_id, sizeof(registry_id), "%" PRIx64, id);
    int location = number_property(device, CFSTR("locationID"));
    char name[IFNAMSIZ] = "-";
    bool has_ecm = ecm_interface(device, name);
    int result = 0;
    if (inspect) {
        char owner[128] = "";
        int pid = 0;
        char process[64] = "-";
        if (string_property(device, CFSTR("UsbExclusiveOwner"), owner, sizeof(owner)) &&
            sscanf(owner, "pid %d, %63[a-zA-Z0-9_.-]", &pid, process) != 2) {
            pid = -1;
        }
        printf("module|%08x|%s|%s|%s|%d|%s\n", (unsigned)location, registry_id,
               has_ecm ? "ecm" : "other", name, pid, process);
    } else if (!has_ecm || strcmp(registry_id, argv[2]) != 0) {
        fputs("The USB device changed or is no longer in ECM mode.\n", stderr);
        result = 1;
    } else {
        result = reenumerate(device);
    }
    IOObjectRelease(device);
    return result;
}
