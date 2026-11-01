#import <Foundation/Foundation.h>
#include <stdint.h>
typedef struct { int32_t board[16]; uintptr_t manager,game,grid; } Auto2048Snapshot;
// Main thread only. Never pass managed objects to background code.
NSString *Auto2048Read(Auto2048Snapshot *out);
NSString *Auto2048Apply(const Auto2048Snapshot *previous, int dir);
