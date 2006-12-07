/*
	Weird options added by chris:
	-mdynamic-no-pic removes useless symbol indirection code, reducing executable size. It does _not_ work for code that may need relocation at runtime, i.e. bundles and frameworks.
	In theory -Wl,-s would avoid a separate invocation of the strip tool, but it ends up stripping bits we actually need.
	-dead_strip tells the linker to remove unused functions and data.
	
    g++ -Wmost -arch ppc -arch i386 -mdynamic-no-pic -dead_strip -isysroot /Developer/SDKs/MacOSX10.4u.sdk -DDATE=\"`date +%Y-%m-%d`\" -Os "$TM_FILEPATH" -o "$TM_SUPPORT_PATH/bin/tm_dialog" -framework Foundation && strip "$TM_SUPPORT_PATH/bin/tm_dialog"

*/
#import <Cocoa/Cocoa.h>
#import <getopt.h>
#import <fcntl.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>
#import <unistd.h>
#import <errno.h>
#import <vector>
#import <string>
#import <sys/stat.h>

#import "TMDSemaphore.h"
#include "TMDSemaphore.mm"		// TODO we should really export this from the plugin instead and link against the plugin
#import "Dialog.h"

char const* AppName = "tm_dialog";

char const* current_version ()
{
	char res[32];
	return sscanf("$Revision$", "$%*[^:]: %s $", res) == 1 ? res : "???";
}

id read_property_list_from_file (int fd)
{
	NSMutableData*	data = [NSMutableData data];
	id plist;
	
	char buf[1024];
	while(size_t len = read(fd, buf, sizeof(buf)))
		[data appendBytes:buf length:len];
	
	plist = [data length] ? [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListMutableContainersAndLeaves format:nil errorDescription:NULL] : [NSMutableDictionary dictionary];
	return plist;
}

id read_property_list_from_string (const char* parameters)
{
	NSMutableData*	data = [NSMutableData data];
	[data appendBytes:parameters length:strlen(parameters)];
	
	id plist = [data length] ? [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListMutableContainersAndLeaves format:nil errorDescription:NULL] : [NSMutableDictionary dictionary];
	
	return plist;
}

bool output_property_list (id plist)
{
	bool res = false;
	NSString* error = nil;
	if(NSData* data = [NSPropertyListSerialization dataFromPropertyList:plist format:NSPropertyListXMLFormat_v1_0 errorDescription:&error])
	{
		if(NSFileHandle* fh = [NSFileHandle fileHandleWithStandardOutput])
		{
			[fh writeData:data];
			res = true;
		}
	}
	else
	{
		fprintf(stderr, "%s: %s\n", AppName, [error UTF8String] ?: "unknown error serializing returned property list");
		fprintf(stderr, "%s\n", [[plist description] UTF8String]);
	}
	return res;
}

// validate_proxy: return an instance of the TM dialog server proxy object. Return false (and write details to stderr)
// if the TM dialog server is unavailable or the protocol version doesn't match.
bool validate_proxy (id & outProxy)
{
	static	bool	proxyValid = false;
	static id 		proxy = nil;
	
	// One shot validate -- if it isn't valid now, presumably it won't be ever
	// (during the very short life of an instance of this tool)
	if(not proxyValid)
	{
		proxy = [NSConnection rootProxyForConnectionWithRegisteredName:@"TextMate dialog server" host:nil];
		[proxy setProtocolForProxy:@protocol(TextMateDialogServerProtocol)];

		if([proxy textMateDialogServerProtocolVersion] == TextMateDialogServerProtocolVersion)
		{
			proxyValid = true;
		}
		else
		{
			if(proxy)
			{
				int pluginVersion = [proxy textMateDialogServerProtocolVersion];
				int toolVersion = TextMateDialogServerProtocolVersion;
				if(pluginVersion < toolVersion)
				{
					fprintf(stderr, "%s: you have updated the tm_dialog tool to v%d but the Dialog plug-in running is still at v%d.\n", AppName, toolVersion, pluginVersion);
					fprintf(stderr, "%s: either checkout the PlugIns folder from the repository or remove your checkout of the Support folder.\n", AppName);
					fprintf(stderr, "%s: if you did checkout the PlugIns folder, you need to relaunch TextMate to load the new plug-in.\n", AppName);
				}
				else
				{
					fprintf(stderr, "%s: you have updated the Dialog plug-in to v%d but the tm_dialog tool is still at v%d\n", AppName, pluginVersion, toolVersion);
				}
			}
			else
			{
				fprintf(stderr, "%s: failed to establish connection with TextMate.\n", AppName);
			}
		}
	}
	
	outProxy = proxy;
	return proxyValid;
}

// contact_server_async_update: update (a subset of) the binding values.
int contact_server_async_update (const char* token, NSMutableDictionary* someParameters)
{
	id	proxy;
	int	returnCode = -1;

	if(validate_proxy(proxy))
	{
		id result = [proxy updateNib:[NSString stringWithUTF8String:token] withParameters:someParameters];
		returnCode = [[result objectForKey:@"returnCode"] intValue];

		if(returnCode == -43)
		{
			fprintf(stderr, "%s (async_update): Window '%s' doesn't exist\n", AppName, token);
		}
	}
	return returnCode;
}

// contact_server_async_close: close the window
int contact_server_async_close (const char* token)
{
	id	proxy;
	int	returnCode = -1;

	if(validate_proxy(proxy))
	{
		id result = [proxy closeNib:[NSString stringWithUTF8String:token]];
		returnCode = [[result objectForKey:@"returnCode"] intValue];
		
		if(returnCode == -43)
		{
			fprintf(stderr, "%s (async_close): Window '%s' doesn't exist\n", AppName, token);
		}
	}

	return returnCode;
}

// contact_server_async_wait: block until returnArgument:, performButtonClick:, or the window is closed,
// then output the resulting plist returned by the dialog server.
int contact_server_async_wait (const char* token)
{
	id	proxy;
	int	returnCode = -1;
	
	if(validate_proxy(proxy))
	{
		id result;
		TMDSemaphore *	semaphore = [TMDSemaphore semaphoreForTokenString:token];
		
//		fprintf(stderr, "%s blocking for window '%s' \n", AppName, token);
//		fflush(stdout);
		[semaphore wait];
//		fprintf(stderr, "%s awake for window '%s' \n", AppName, token);
//		fflush(stdout);
		result = [proxy retrieveNibResults:[NSString stringWithUTF8String:token]];
		returnCode = [[result objectForKey:@"returnCode"] intValue];

		if(returnCode == -43)
		{
			fprintf(stderr, "%s (async_wait): Window '%s' doesn't exist\n", AppName, token);
		}

		output_property_list(result);
	}

	return returnCode;
}


// contact_server_async_list: print a list of windows to stdout
int contact_server_async_list ()
{
	id	proxy;
	int	returnCode = -1;
	
	if(validate_proxy(proxy))
	{
		id result = [proxy listNibTokens];
		returnCode = [[result objectForKey:@"returnCode"] intValue];
		
		if(returnCode != 0)
		{
			fprintf(stderr, "%s: Unknown error code '%d'\n", AppName, returnCode);
		}
		else
		{
			NSArray* nibs = [result objectForKey:@"nibs"];
			enumerate(nibs, NSDictionary * nib)
			{
				NSString*	windowTitleString	= [nib objectForKey:@"windowTitle"];
				const char* windowTitleC		= "<no title>";
				int			windowToken			= [[nib objectForKey:@"token"] intValue];

				if(windowTitleString != nil
					&& not [windowTitleString isEqualToString:@""])
				{
					windowTitleC = [windowTitleString UTF8String];
				}				
				fprintf(stdout, "%d (%s)\n", windowToken, windowTitleC);
			}
		}
	}

	return returnCode;
}

// contact_server_show_nib: instantiate the nib inside TM
int contact_server_show_nib (std::string nibName, NSMutableDictionary* someParameters, NSDictionary* initialValues, bool center, bool modal, bool quiet, bool async)
{
	int res = -1;
	id proxy;
	
	if(validate_proxy(proxy))
	{
		NSString* aNibPath = [NSString stringWithUTF8String:nibName.c_str()];
		NSDictionary* parameters = (NSDictionary*)[proxy showNib:aNibPath withParameters:someParameters andInitialValues:initialValues modal:modal center:center async:async];

		const char*	token = [[NSString stringWithFormat:@"%@", [parameters objectForKey:@"token"]] UTF8String];
		
		res = [[parameters objectForKey:@"returnCode"] intValue];
		
		// Async mode: print just the token for the new window
		if(async)
		{
			if(res == 0)
			{
				fprintf(stdout, "%d\n", [[parameters objectForKey:@"token"] intValue]);
			}
			else
			{
				fprintf(stderr, "Error %d creating window\n", res);
			}
		}
		else if(modal)
		{
			if(not quiet)
			{
				output_property_list(parameters);
			}
		}
		else
		{
			// Not async, not modal. The task had better be detached from TM, or TM will hang
			// until the task is killed. Wait until something happens.
			res = contact_server_async_wait(token);
			contact_server_async_close(token);
		}
		
	}
	return res;
}

void usage ()
{
	fprintf(stderr, 
		"%1$s r%2$s (" DATE ")\n"
		"Usage: %1$s [-cmqpaxt] nib_file\n"
		"Usage: %1$s [-p] -u\n"
		"\n"
		"Options:\n"
      " -c, --center                 Center the window on screen.\n"
      " -d, --defaults <plist>       Register initial values for user defaults.\n"
      " -m, --modal                  Show window as modal (other windows will be inaccessible).\n"
      " -q, --quiet                  Do not write result to stdout.\n"
      " -p, --parameters <plist>     Provide parameters as a plist.\n"
      " -u, --menu                   Treat parameters as a menu structure.\n"
      "\n Async Window Subcommands\n"
      " -a, --async-window           Displays the window and returns a reference token for it\n"
      "                              in the output property list.\n"
      " -x, --close-window <token>   Close and release an async window.\n"
      " -t, --update-window <token>  Update an async window with new parameter values.\n"
	  "                              Use the --parameters argument (or stdin) to specify the\n"
	  "                              updated parameters.\n"
      " -l, --list-windows           List async window tokens.\n"
      " -w, --wait-for-input <token> Wait for user input from the given async window.\n"
	  "\nImportant Note\n"
	  "If you DO NOT use the -m/--modal option,\n"
	  "OR you create an async window and then use the wait-for-input subcommand,\n"
	  "you must run tm_dialog in a detached/backgrounded process (`mycommand 2&>1 &` in bash).\n"
	  "Otherwise, TextMate's UI thread will hang, waiting for your command to complete.\n"
	  "You can recover from the hang by killing the tm_dialog process in Terminal.\n"
	  "Better not to cause it in the first place, though. :)\n"
		"\n"
		"", AppName, current_version());
}

std::string find_nib (std::string nibName)
{
	std::vector<std::string> candidates;

	if(nibName.find(".nib") == std::string::npos)
		nibName += ".nib";

	if(nibName.size() && nibName[0] != '/') // relative path
	{
		if(char const* currentPath = getcwd(NULL, 0))
			candidates.push_back(currentPath + std::string("/") + nibName);

		if(char const* bundleSupport = getenv("TM_BUNDLE_SUPPORT"))
			candidates.push_back(bundleSupport + std::string("/nibs/") + nibName);

		if(char const* supportPath = getenv("TM_SUPPORT_PATH"))
			candidates.push_back(supportPath + std::string("/nibs/") + nibName);
	}
	else
	{
		candidates.push_back(nibName);
	}

	for(typeof(candidates.begin()) it = candidates.begin(); it != candidates.end(); ++it)
	{
		struct stat sb;
		if(stat(it->c_str(), &sb) == 0)
			return *it;
	}

	fprintf(stderr, "nib could not be loaded: %s (does not exist)\n", nibName.c_str());
	abort();
	return NULL;
}

id read_property_list_argument(const char* parameters)
{
	id plist = nil;
	if(parameters)
	{
		plist = read_property_list_from_string(parameters);
	}
	else
	{
//		if(isatty(STDIN_FILENO) == 0)
		{
			plist = read_property_list_from_file(STDIN_FILENO);
		}
	}
	
	return plist;
}

int main (int argc, char* argv[])
{
	NSAutoreleasePool* pool = [NSAutoreleasePool new];

	extern int optind;
	extern char* optarg;

	enum AsyncWindowAction
	{
		kSyncCreate,
		kAsyncCreate,
		kAsyncClose,
		kAsyncUpdate,
		kAsyncList,
		kAsyncWait
	};

	static struct option const longopts[] = {
		{ "center",				no_argument,			0,		'c'	},
		{ "defaults",			required_argument,	0,		'd'	},
		{ "modal",				no_argument,			0,		'm'	},
		{ "parameters",		required_argument,	0,		'p'	},
		{ "quiet",				no_argument,			0,		'q'	},
		{ "menu",				no_argument,			0,		'u'	},
		{ "async-window",				no_argument,			0,		'a'	},
		{ "close-window",				required_argument,			0,		'x'	},
		{ "update-window",				required_argument,			0,		't'	},
		{ "wait-for-input",				required_argument,			0,		'w'	},
		{ "list-windows",				no_argument,			0,		'l'	},
		{ 0,						0,							0,		0		}
	};

	bool center = false, modal = false, quiet = false, menu = false;
	char const* parameters = NULL;
	char const* defaults = NULL;
	char const* token = NULL;
	char ch;
	AsyncWindowAction asyncWindowAction = kSyncCreate;
	
	while((ch = getopt_long(argc, argv, "cd:mp:quax:t:w:l", longopts, NULL)) != -1)
	{
		switch(ch)
		{
			case 'c':	center = true;				break;
			case 'd':	defaults = optarg;		break;
			case 'm':	modal = true;				break;
			case 'p':	parameters = optarg;		break;
			case 'q':	quiet = true;				break;
			case 'u':	menu = true;				break;
			
			case 'a':	asyncWindowAction = kAsyncCreate;				break;
			case 'x':	asyncWindowAction = kAsyncClose; token = optarg;			break;
			case 't':	asyncWindowAction = kAsyncUpdate; token = optarg;			break;
			case 'w':	asyncWindowAction = kAsyncWait; token = optarg;			break;
			case 'l':	asyncWindowAction = kAsyncList;			break;

			default:		usage();						break;
		}
	}

	argc -= optind;
	argv += optind;

	int res = -1;
	if(not menu)
	{
		id initialValues = defaults ? [NSPropertyListSerialization propertyListFromData:[NSData dataWithBytes:defaults length:strlen(defaults)] mutabilityOption:NSPropertyListImmutable format:nil errorDescription:NULL] : nil;

		if(asyncWindowAction != kSyncCreate)
		{
			if(modal)
				fprintf(stderr, "%s: warning: Ignoring 'modal' option; async windows cannot be modal\n", AppName);
			
			if(quiet)
				fprintf(stderr, "%s: warning: Ignoring 'quiet' option for async window; use a normal window instead.\n", AppName);
		}

		switch(asyncWindowAction)
		{
			case kSyncCreate:
			case kAsyncCreate:
				if(argc == 1)
				{
					id plist = read_property_list_argument(parameters);
					res = contact_server_show_nib(find_nib(argv[0]), plist, initialValues, center, modal, quiet, (asyncWindowAction == kAsyncCreate));
				}
				else
				{
					usage();
				}
				break;
			case kAsyncUpdate:	
			{
				id plist = read_property_list_argument(parameters);
				res = contact_server_async_update(token, plist);
			} break;
			case kAsyncClose:
				res = contact_server_async_close(token);
				break;
			case kAsyncWait:
				res = contact_server_async_wait(token);
				break;
			case kAsyncList:
				res = contact_server_async_list();
				break;
			default:
				usage();
				break;
		}
	}
	else if(argc == 0)
	{
		id proxy;
		if(validate_proxy(proxy))
		{
			id plist = read_property_list_argument(parameters);
			output_property_list([proxy showMenuWithOptions:plist]);
		}
	}
	else
	{
		usage();
	}

	[pool release];
	return res;
}
