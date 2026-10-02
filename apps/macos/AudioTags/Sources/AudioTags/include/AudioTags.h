#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface AudioTags : NSObject
+ (nullable NSDictionary<NSString *, id> *)readFile:(NSURL *)url error:(NSError **)error;
+ (BOOL)writeFile:(NSURL *)url fields:(NSDictionary<NSString *, NSString *> *)fields
        artwork:(nullable NSData *)artwork mimeType:(nullable NSString *)mimeType
    changeArtwork:(BOOL)changeArtwork error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
