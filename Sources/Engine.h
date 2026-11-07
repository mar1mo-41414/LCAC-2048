#import <Foundation/Foundation.h>
#include <stdint.h>
typedef struct { int32_t board[16]; uintptr_t manager,game,grid; } Auto2048Snapshot;
// Main thread only. Never pass managed objects to background code.
NSString *Auto2048Read(Auto2048Snapshot *out);
NSString *Auto2048Apply(const Auto2048Snapshot *previous, int dir);
// True when the board read last time had no move left.
BOOL Auto2048GameOver(void);
// Asks the game to start over ("play again"). Returns "ON" when the call was
// made, "NO" when there was nothing to restart. Main thread only.
NSString *Auto2048Restart(void);
// 盤面がまだ落ち着いていないので 1 フレーム見送った、と知らせる (ログ用の計数)。
void Auto2048NoteSettleWait(void);
