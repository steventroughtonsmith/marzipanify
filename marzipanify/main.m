//
//  main.m
//  marzipanify
//
//  Created by Steven Troughton-Smith on 16/06/2018.
//  Copyright © 2018 Steven Troughton-Smith. All rights reserved.
//

@import Foundation;
@import ObjectiveC.runtime;
@import MachO;
@import vmnet;

void processEmbeddedBundle(NSString *bundlePath);
void processEmbeddedLibrary(NSString *libraryPath);

NSArray *__whitelistedMacFrameworks = nil;

#define DEBUG_PRINT_COMMANDLINE 0

NSString *binaryPathForBundlePath(NSString *bundlePath)
{
	NSString *infoPlistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
	NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
	NSString *executableName = infoPlist[@"CFBundleExecutable"];
	NSString *executablePath = [bundlePath stringByAppendingPathComponent:executableName];
	
	return executablePath;
}

void processInfoPlist(NSString *infoPlistPath)
{
	NSMutableDictionary *infoPlist = [NSMutableDictionary dictionaryWithContentsOfFile:infoPlistPath];
	infoPlist[@"LSRequiresIPhoneOS"] = @NO;
	infoPlist[@"CFBundleSupportedPlatforms"] = @[@"MacOSX"];
	infoPlist[@"MinimumOSVersion"] = @"10.14";
	
	[infoPlist removeObjectForKey:@"DTSDKName"];
	[infoPlist removeObjectForKey:@"DTSDKBuild"];
	[infoPlist removeObjectForKey:@"DTCompiler"];
	[infoPlist removeObjectForKey:@"DTPlatformBuild"];
	[infoPlist removeObjectForKey:@"DTPlatformVersion"];
	[infoPlist removeObjectForKey:@"DTXcode"];
	[infoPlist removeObjectForKey:@"DTXcodeBuild"];
	[infoPlist removeObjectForKey:@"DTPlatformName"];
	
	infoPlist[@"LSEnvironment"] = @{@"CFMZEnabled" : @"1"};
	
	[infoPlist writeToFile:infoPlistPath atomically:NO];
}

BOOL repackageAppBundle(NSString *bundlePath)
{
	NSString *infoPlistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
	NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
	NSString *executableName = infoPlist[@"CFBundleExecutable"];
	
	NSString *macOSPath = [bundlePath stringByAppendingPathComponent:@"Contents/MacOS"];
	NSString *resourcesPath = [bundlePath stringByAppendingPathComponent:@"Contents/Resources"];
	NSString *contentsPath = [bundlePath stringByAppendingPathComponent:@"Contents/"];
	
	processInfoPlist(infoPlistPath);
	
	[[NSFileManager defaultManager] createDirectoryAtPath:macOSPath withIntermediateDirectories:YES attributes:nil error:nil];
	[[NSFileManager defaultManager] createDirectoryAtPath:resourcesPath withIntermediateDirectories:YES attributes:nil error:nil];
	
	NSArray *bundleContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundlePath error:nil];
	
	for (NSString *item in bundleContents)
	{
		NSString *itemPath = [bundlePath stringByAppendingPathComponent:item];
		
		if ([item isEqualToString:executableName])
		{
			[[NSFileManager defaultManager] moveItemAtPath:itemPath toPath:[macOSPath stringByAppendingPathComponent:item] error:nil];
		}
		else if ([item isEqualToString:@"Info.plist"])
		{
			[[NSFileManager defaultManager] moveItemAtPath:itemPath toPath:[contentsPath stringByAppendingPathComponent:item] error:nil];
		}
		else if ([item isEqualToString:@"PkgInfo"])
		{
			[[NSFileManager defaultManager] moveItemAtPath:itemPath toPath:[contentsPath stringByAppendingPathComponent:item] error:nil];
		}
		else if ([item isEqualToString:@"Frameworks"])
		{
			[[NSFileManager defaultManager] moveItemAtPath:itemPath toPath:[contentsPath stringByAppendingPathComponent:item] error:nil];
		}
		else if ([item isEqualToString:@"Plug-Ins"])
		{
			[[NSFileManager defaultManager] moveItemAtPath:itemPath toPath:[contentsPath stringByAppendingPathComponent:item] error:nil];
		}
		else if ([item isEqualToString:@"_CodeSignature"])
		{
			[[NSFileManager defaultManager] moveItemAtPath:itemPath toPath:[contentsPath stringByAppendingPathComponent:item] error:nil];
		}
		else
		{
			[[NSFileManager defaultManager] moveItemAtPath:itemPath toPath:[resourcesPath stringByAppendingPathComponent:item] error:nil];
		}
	}
	
	return YES;
}

NSArray *arrayOfLoadedDylibs(NSString *binaryPath)
{
	NSMutableArray *dylibs = @[].mutableCopy;
	NSDictionary *attribs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:binaryPath error:nil];
	
	long sz = [attribs[@"NSFileSystemSize"] longValue];
	
	int handle = open(binaryPath.UTF8String, O_RDWR, 0);
	char *macho = mmap(NULL, sz, PROT_READ|PROT_WRITE, MAP_SHARED, handle, 0);
	
	if (handle == -1)
	{
		printf("ERROR: can't load %s", binaryPath.UTF8String);
		close(handle);
		return @[];
	}
	
	const struct fat_header *header_fat = (struct fat_header *)macho;
	uint8_t *imageHeaderPtr = (uint8_t*)macho;
	
	long header64offset = 0;

	if (header_fat->magic == FAT_CIGAM || header_fat->magic == FAT_MAGIC)
	{
		int narchs = OSSwapBigToHostInt32(header_fat->nfat_arch);
		imageHeaderPtr += sizeof(header_fat);

		for (int i = 0; i < narchs; i++)
		{
			struct fat_arch uarch = *(struct fat_arch*)imageHeaderPtr;
			
			if (OSSwapBigToHostInt32(uarch.cputype) == CPU_TYPE_X86_64)
			{
				//printf("mach_header_64 offset = %u\n", OSSwapBigToHostInt32(uarch.offset));
				header64offset = OSSwapBigToHostInt32(uarch.offset) -32 + sizeof(struct mach_header_64);
				break;
			}
			else if (OSSwapBigToHostInt32(uarch.cputype) == CPU_TYPE_ARM64)
			{
				//printf("mach_header_64 offset = %u\n", OSSwapBigToHostInt32(uarch.offset));
				header64offset = OSSwapBigToHostInt32(uarch.offset) -32 + sizeof(struct mach_header_64);
				break;
			}
			else
				imageHeaderPtr += sizeof(struct fat_arch);
		}
		
		if (header64offset == 0)
		{
			printf("ERROR: No X86_64 or ARM64 slice found.\n");
			exit(-1);
		}
	}

	imageHeaderPtr = (uint8_t*)(macho+header64offset);
	
	typedef struct load_command load_command;
	const struct mach_header_64 *header64 = (struct mach_header_64 *)imageHeaderPtr;
	
	if (header64->magic != MH_MAGIC_64)
		return @[];

	imageHeaderPtr += sizeof(struct mach_header_64);
	load_command *command = (load_command*)(imageHeaderPtr);

	for(int i = 0; i < header64->ncmds > 0; ++i)
	{
		if(command->cmd == LC_LOAD_DYLIB)
		{
			struct dylib_command ucmd = *(struct dylib_command*)imageHeaderPtr;
			int offset = ucmd.dylib.name.offset;
			int size = ucmd.cmdsize;
			
			char *name = (char *)malloc(size);
			memset(name, 0, size);
			
			strncpy(name, (char *)(imageHeaderPtr+offset), (size));
			
			//printf("LC_LOAD_DYLIB %s\n", name);
			[dylibs addObject:[NSString stringWithUTF8String:name]];
		}
		else if(command->cmd == LC_VERSION_MIN_IPHONEOS)
		{
			//printf("WARNING: This bundle (%s) was built with an earlier iOS SDK. It will require the CFMZEnabled=1 environment variable (which will be added to its Info.plist).\n", binaryPath.lastPathComponent.UTF8String);
			struct version_min_command ucmd = *(struct version_min_command*)imageHeaderPtr;
			ucmd.cmd = LC_VERSION_MIN_MACOSX;
			ucmd.sdk = 10<<16|14<<8|0;
			ucmd.version = 10<<16|14<<8|0;
			
			memcpy(imageHeaderPtr, &ucmd, ucmd.cmdsize);
		}
		else if(command->cmd == LC_BUILD_VERSION)
		{
			struct build_version_command ucmd = *(struct build_version_command*)imageHeaderPtr;
			ucmd.platform = PLATFORM_IOSMAC;
			ucmd.minos = 12<<16|0<<8|0;
			ucmd.sdk = 10<<16|14<<8|0;
			
			memcpy(imageHeaderPtr, &ucmd, ucmd.cmdsize);
		}
		
		imageHeaderPtr += command->cmdsize;
		command = (load_command*)imageHeaderPtr;
	}
	
	msync(macho, sz, MS_SYNC);
	
	munmap(macho, sz);
	close(handle);
	
	return [NSArray arrayWithArray:dylibs];
}

NSString *newLinkerPathForLoadedDylib(NSString *loadedDylib)
{
	if ([loadedDylib hasPrefix:@"/System/iOSSupport"] || [loadedDylib hasPrefix:@"/System/iOSSimulator"])
		return loadedDylib;
	
	NSString *possibleiOSMacDylibPath = [@"/System/iOSSupport" stringByAppendingPathComponent:loadedDylib];
	//NSString *possibleSimulatorDylibPath = [@"/System/iOSSimulator" stringByAppendingPathComponent:loadedDylib];

	if ([[NSFileManager defaultManager] fileExistsAtPath:possibleiOSMacDylibPath])
	{
		return possibleiOSMacDylibPath;
	}
	
	
	if (![[NSFileManager defaultManager] fileExistsAtPath:loadedDylib] && ![loadedDylib hasPrefix:@"@rpath"] && ![loadedDylib hasPrefix:@"@executable_path"])
	{
		printf("WARNING: no linker redirect available for %s\n", loadedDylib.UTF8String);
	}
	
	return loadedDylib;
}

void dumpEntitlementsForBinary(NSString *appBundlePath, NSString *appBinaryPath)
{
	NSString *entitlementCommand = [NSString stringWithFormat:@"codesign -d --entitlements :- \"%@\" > \"Entitlements-%@\".plist &> /dev/null", appBundlePath, appBinaryPath.lastPathComponent];
	
#if DEBUG_PRINT_COMMANDLINE
	printf("%s\n", entitlementCommand.UTF8String);
#endif
	system(entitlementCommand.UTF8String);
}

void resignBinary(NSString *appBundlePath, NSString *appBinaryPath)
{
	NSString *entitlementsPath = [NSString stringWithFormat:@"Entitlements-%@.plist", appBinaryPath.lastPathComponent];
	
	NSMutableDictionary *entitlementsDict = [NSMutableDictionary dictionaryWithContentsOfFile:entitlementsPath];
	
	if (!entitlementsDict)
		entitlementsDict = @{}.mutableCopy;
	
	entitlementsDict[@"com.apple.private.iosmac"] = @YES;
	[entitlementsDict writeToFile:entitlementsPath atomically:NO];
	
	NSString *resignCommand = [NSString stringWithFormat:@"/usr/bin/codesign --force --sign - --entitlements \"%@\" --timestamp=none \"%@\" &> /dev/null", entitlementsPath, appBundlePath];
#if DEBUG_PRINT_COMMANDLINE
	printf("%s\n", resignCommand.UTF8String);
#endif
	system(resignCommand.UTF8String);
}


void processEmbeddedBundle(NSString *bundlePath)
{
	NSString *infoPlistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
	NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
	NSString *executableName = infoPlist[@"CFBundleExecutable"];
	
	NSString *frameworkBinaryPath = [bundlePath stringByAppendingPathComponent:executableName];
	NSString *embeddedBundlesPath = [bundlePath stringByAppendingPathComponent:@"Frameworks"];
	
	NSArray *embeddedBundles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:embeddedBundlesPath error:nil];
	
	if (embeddedBundles)
	{
		for (NSString *framework in embeddedBundles)
		{
			if ([framework hasSuffix:@".framework"] || [framework hasSuffix:@".bundle"])
			{
				processEmbeddedBundle([embeddedBundlesPath stringByAppendingPathComponent:framework]);
			}
			else if ([framework hasSuffix:@".dylib"])
			{
				processEmbeddedLibrary([embeddedBundlesPath stringByAppendingPathComponent:framework]);
			}
			else
			{
				
			}
		}
	}
	
	dumpEntitlementsForBinary(bundlePath, frameworkBinaryPath);
	
	/* Do Linker Redirects */
	
	NSArray *dylibs = arrayOfLoadedDylibs(frameworkBinaryPath);
	
	for (NSString *dylib in dylibs)
	{
		NSString *redirectedDylib = newLinkerPathForLoadedDylib(dylib);
		
		if (![dylib isEqualToString:redirectedDylib])
		{
			
			NSString *install_name_tool_command = [NSString stringWithFormat:@"install_name_tool -change \"%@\" \"%@\" \"%@\"", dylib, redirectedDylib, frameworkBinaryPath];
			
#if DEBUG_PRINT_COMMANDLINE
			printf("%s\n", install_name_tool_command.UTF8String);
#endif
			system([install_name_tool_command UTF8String]);
		}
	}
	
	resignBinary(bundlePath, frameworkBinaryPath);
}

void processEmbeddedLibrary(NSString *libraryPath)
{
	NSString *frameworkBinaryPath = libraryPath;
	
	dumpEntitlementsForBinary(frameworkBinaryPath, frameworkBinaryPath);
	
	/* Do Linker Redirects */
	
	NSArray *dylibs = arrayOfLoadedDylibs(frameworkBinaryPath);
	
	for (NSString *dylib in dylibs)
	{
		NSString *redirectedDylib = newLinkerPathForLoadedDylib(dylib);
		
		if (![dylib isEqualToString:redirectedDylib])
		{
			
			NSString *install_name_tool_command = [NSString stringWithFormat:@"install_name_tool -change \"%@\" \"%@\" \"%@\"", dylib, redirectedDylib, frameworkBinaryPath];
			
#if DEBUG_PRINT_COMMANDLINE
			printf("%s\n", install_name_tool_command.UTF8String);
#endif
			system([install_name_tool_command UTF8String]);
		}
	}
	
	resignBinary(frameworkBinaryPath, frameworkBinaryPath);
}

void print_usage()
{
	printf("usage: marzipanify MyApp.app\n\n");
}

//int __main(int argc, const char * argv[])
//{
//	NSString *frameworksPath = @"/System/iOSSimulator/System/Library/Frameworks";
//
//	NSArray *frameworks = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:frameworksPath error:nil];
//
//	for (NSString *framework in frameworks)
//	{
//		processEmbeddedBundle([frameworksPath stringByAppendingPathComponent:framework]);
//	}
//
//	return 0;
//}

void loadWhitelist()
{
	__whitelistedMacFrameworks = [[NSString stringWithContentsOfFile:@"/System/iOSSupport/dyld/macOS-whitelist.txt" usedEncoding:nil error:nil] componentsSeparatedByString:@"\n"];
}

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		
		if (argc < 2)
		{
			print_usage();
			return -1;
		}
		
		NSString *appBundlePath = [NSString stringWithUTF8String:argv[1]];
		NSString *appBinaryPath = binaryPathForBundlePath(appBundlePath);
		NSString *embeddedFrameworksPath = [appBundlePath stringByAppendingPathComponent:@"Frameworks"];
		
		loadWhitelist();
		
		if ([appBundlePath hasSuffix:@".framework"] || [appBundlePath hasSuffix:@".bundle"])
		{
			processEmbeddedBundle(appBundlePath);
			return 0;
		}
		
		if (![appBundlePath hasSuffix:@".app"] || ![[NSFileManager defaultManager] fileExistsAtPath:appBundlePath isDirectory:nil])
		{
			print_usage();
			return -1;
		}
		
		/* Dump Entitlements */
		
		dumpEntitlementsForBinary(appBundlePath, appBinaryPath);
		
		/* Do Linker Redirects */
		
		NSArray *dylibs = arrayOfLoadedDylibs(appBinaryPath);
		
		for (NSString *dylib in dylibs)
		{
			NSString *redirectedDylib = newLinkerPathForLoadedDylib(dylib);
			
			if (![dylib isEqualToString:redirectedDylib])
			{
				
				NSString *install_name_tool_command = [NSString stringWithFormat:@"install_name_tool -change \"%@\" \"%@\" \"%@\"", dylib, redirectedDylib, appBinaryPath];
				
#if DEBUG_PRINT_COMMANDLINE
				printf("%s\n", install_name_tool_command.UTF8String);
#endif
				system([install_name_tool_command UTF8String]);
			}
		}
		
		/* Add @rpath */
		
		NSString *rpathCommand = [NSString stringWithFormat:@"install_name_tool -add_rpath \"@executable_path/../Frameworks/\" \"%@\"", appBinaryPath];
		
#if DEBUG_PRINT_COMMANDLINE
		printf("%s\n", rpathCommand.UTF8String);
#endif
		system(rpathCommand.UTF8String);
		
		/* Process Frameworks */
		
		NSArray *embeddedFrameworks = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:embeddedFrameworksPath error:nil];
		
		for (NSString *framework in embeddedFrameworks)
		{
			if ([framework hasSuffix:@".framework"] || [framework hasSuffix:@".bundle"])
			{
				processEmbeddedBundle([embeddedFrameworksPath stringByAppendingPathComponent:framework]);
			}
			else
			{
				processEmbeddedLibrary([embeddedFrameworksPath stringByAppendingPathComponent:framework]);
			}
		}
		
		/* Package App */
		
		repackageAppBundle(appBundlePath);
		
		/* Re-sign */
		
		resignBinary(appBundlePath, appBinaryPath);
	}
	return 0;
}
