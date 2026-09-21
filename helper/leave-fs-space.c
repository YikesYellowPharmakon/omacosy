/*
 * omacosy-leave-fs-space — show this display's desktop Space without
 * toggling macos-native-fullscreen. Native fullscreen is its own Space;
 * AeroSpace already updated the desktop workspace underneath.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

typedef int (*SLSMainConnectionID_fn)(void);
typedef CFArrayRef (*SLSCopyManagedDisplaySpaces_fn)(int);
typedef CFStringRef (*SLSCopyBestManagedDisplayForPoint_fn)(int, CGPoint);
typedef uint64_t (*SLSManagedDisplayGetCurrentSpace_fn)(int, CFStringRef);
typedef int (*SLSSpaceGetType_fn)(int, uint64_t);
typedef CGError (*SLSManagedDisplaySetCurrentSpace_fn)(int, CFStringRef, uint64_t);

static void *sym(void *h, const char *name)
{
	void *p = dlsym(h, name);
	return p;
}

static uint64_t num_from(CFDictionaryRef d, CFStringRef key)
{
	if (!d)
		return 0;
	CFNumberRef n = CFDictionaryGetValue(d, key);
	if (!n || CFGetTypeID(n) != CFNumberGetTypeID())
		return 0;
	uint64_t v = 0;
	CFNumberGetValue(n, kCFNumberSInt64Type, &v);
	return v;
}

int main(void)
{
	void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
	if (!h)
		return 1;

	SLSMainConnectionID_fn SLSMainConnectionID = sym(h, "SLSMainConnectionID");
	SLSCopyManagedDisplaySpaces_fn SLSCopyManagedDisplaySpaces = sym(h, "SLSCopyManagedDisplaySpaces");
	SLSCopyBestManagedDisplayForPoint_fn SLSCopyBestManagedDisplayForPoint = sym(h, "SLSCopyBestManagedDisplayForPoint");
	SLSManagedDisplayGetCurrentSpace_fn SLSManagedDisplayGetCurrentSpace = sym(h, "SLSManagedDisplayGetCurrentSpace");
	SLSSpaceGetType_fn SLSSpaceGetType = sym(h, "SLSSpaceGetType");
	SLSManagedDisplaySetCurrentSpace_fn SLSManagedDisplaySetCurrentSpace = sym(h, "SLSManagedDisplaySetCurrentSpace");
	if (!SLSMainConnectionID || !SLSCopyManagedDisplaySpaces ||
	    !SLSCopyBestManagedDisplayForPoint || !SLSManagedDisplayGetCurrentSpace ||
	    !SLSManagedDisplaySetCurrentSpace)
		return 1;

	int cid = SLSMainConnectionID();
	CGEventRef ev = CGEventCreate(NULL);
	CGPoint p = ev ? CGEventGetLocation(ev) : CGPointZero;
	if (ev)
		CFRelease(ev);

	CFStringRef uuid = SLSCopyBestManagedDisplayForPoint(cid, p);
	if (!uuid)
		return 1;

	uint64_t cur = SLSManagedDisplayGetCurrentSpace(cid, uuid);
	int typ = SLSSpaceGetType ? SLSSpaceGetType(cid, cur) : -1;
	/* 0 = user desktop. Anything else (fullscreen / split) stays put. */
	if (typ == 0) {
		CFRelease(uuid);
		return 0;
	}

	CFArrayRef displays = SLSCopyManagedDisplaySpaces(cid);
	if (!displays) {
		CFRelease(uuid);
		return 1;
	}

	uint64_t user = 0;
	CFIndex n = CFArrayGetCount(displays);
	for (CFIndex i = 0; i < n && !user; i++) {
		CFDictionaryRef disp = CFArrayGetValueAtIndex(displays, i);
		if (!disp || CFGetTypeID(disp) != CFDictionaryGetTypeID())
			continue;
		CFStringRef id = CFDictionaryGetValue(disp, CFSTR("Display Identifier"));
		if (!id || CFStringCompare(id, uuid, 0) != kCFCompareEqualTo)
			continue;
		CFArrayRef spaces = CFDictionaryGetValue(disp, CFSTR("Spaces"));
		if (!spaces || CFGetTypeID(spaces) != CFArrayGetTypeID())
			continue;
		CFIndex m = CFArrayGetCount(spaces);
		for (CFIndex j = 0; j < m; j++) {
			CFDictionaryRef sp = CFArrayGetValueAtIndex(spaces, j);
			if (!sp || CFGetTypeID(sp) != CFDictionaryGetTypeID())
				continue;
			uint64_t st = num_from(sp, CFSTR("type"));
			if (st != 0)
				continue;
			uint64_t sid = num_from(sp, CFSTR("id64"));
			if (!sid)
				sid = num_from(sp, CFSTR("ManagedSpaceID"));
			if (sid) {
				user = sid;
				break;
			}
		}
	}
	CFRelease(displays);

	int rc = 1;
	if (user && user != cur) {
		if (SLSManagedDisplaySetCurrentSpace(cid, uuid, user) == 0)
			rc = 0;
	} else if (typ == 0) {
		rc = 0;
	}
	CFRelease(uuid);
	return rc;
}
