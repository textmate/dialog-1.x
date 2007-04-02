// 
//  TMDSemaphore.mm
//  TM dialog server
//  
//  Created by Chris Thomas on 2006-12-06.
// 

#import "TMDSemaphore.h"

@implementation TMDSemaphore

+ (NSString *)nameForToken:(int)token
{
	return [NSString stringWithFormat:@"/tm_dialog async/%@/%d", NSUserName(), token];
}

+ (NSString *)nameForTokenString:(const char *)token
{
	return [NSString stringWithFormat:@"/tm_dialog async/%@/%s", NSUserName(), token];
}

+ (TMDSemaphore*)semaphoreForTokenString:(const char *)token
{
	return [self semaphoreWithName:[self nameForTokenString:token]];
}

+ (TMDSemaphore*)semaphoreForTokenInt:(int)token
{
	return [self semaphoreWithName:[self nameForToken:token]];
}

+ (TMDSemaphore*)semaphoreWithName:(NSString *)name
{
	return [[[self alloc] initWithName:name] autorelease];
}

- (id)initWithName:(NSString *)inName;
{
	name = [inName copy];
	if(self = [super init])
	{
		semaphore = sem_open([name UTF8String], O_CREAT, 0600, 0);
		if(semaphore == (sem_t*)SEM_FAILED)
		{
			int error = errno;
			fprintf(stderr, "error %d (%s) opening sem %s.\n", error, strerror(error), [name UTF8String]);
			fflush(stderr);
		}
	}
	return self;
}

- (void)dealloc
{
	if(semaphore != (sem_t*)SEM_FAILED)
	{
		sem_close(semaphore);
		sem_unlink([name UTF8String]);
	}
	[name release];
	[super dealloc];
}

- (void)wait
{
	sem_wait(semaphore);
}

- (void)stopWaiting
{
	sem_post(semaphore);
}
@end