#import "AudioTags.h"
#include <taglib/fileref.h>
#include <taglib/tpropertymap.h>
#include <taglib/tvariant.h>

static BOOL fail(NSError **error, NSString *message) {
    if(error) *error = [NSError errorWithDomain:@"syncstr.AudioTags" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

@implementation AudioTags
+ (NSDictionary<NSString *, id> *)readFile:(NSURL *)url error:(NSError **)error {
    TagLib::FileRef file(url.fileSystemRepresentation, false);
    if(file.isNull() || !file.file()->isValid()) {
        fail(error, @"この音楽形式の曲情報を読み込めませんでした。");
        return nil;
    }
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for(const auto &entry : file.properties()) {
        NSMutableArray *values = [NSMutableArray array];
        for(const auto &value : entry.second) {
            [values addObject:[NSString stringWithUTF8String:value.toCString(true)]];
        }
        result[[NSString stringWithUTF8String:entry.first.toCString(true)]] = values;
    }
    const auto pictures = file.complexProperties("PICTURE");
    for(const auto &picture : pictures) {
        const auto data = picture["data"].toByteVector();
        if(data.isEmpty()) continue;
        if(!result[@"artwork"] || picture["pictureType"].toString() == "Front Cover") {
            result[@"artwork"] = [NSData dataWithBytes:data.data() length:data.size()];
            if(picture["pictureType"].toString() == "Front Cover") break;
        }
    }
    return result;
}

+ (BOOL)writeFile:(NSURL *)url fields:(NSDictionary<NSString *, NSString *> *)fields
         artwork:(NSData *)artwork mimeType:(NSString *)mimeType
   changeArtwork:(BOOL)changeArtwork error:(NSError **)error {
    TagLib::FileRef file(url.fileSystemRepresentation, false);
    if(file.isNull() || !file.file()->isValid()) return fail(error, @"曲情報を編集できない音楽形式です。");
    auto properties = file.properties();
    for(NSString *key in fields) {
        TagLib::String name(key.UTF8String, TagLib::String::UTF8);
        NSString *value = fields[key];
        if(value.length == 0) properties.erase(name);
        else properties[name] = TagLib::StringList(TagLib::String(value.UTF8String, TagLib::String::UTF8));
    }
    if(!file.setProperties(properties).isEmpty()) return fail(error, @"この形式では一部の曲情報を保存できません。");
    if(changeArtwork) {
        TagLib::List<TagLib::VariantMap> pictures;
        for(const auto &picture : file.complexProperties("PICTURE")) {
            if(artwork && picture["pictureType"].toString() != "Front Cover") pictures.append(picture);
        }
        if(artwork) {
            TagLib::VariantMap picture;
            picture["data"] = TagLib::ByteVector((const char *)artwork.bytes, (unsigned int)artwork.length);
            picture["mimeType"] = TagLib::String(mimeType.UTF8String, TagLib::String::UTF8);
            picture["pictureType"] = TagLib::String("Front Cover");
            picture["description"] = TagLib::String("");
            pictures.prepend(picture);
        }
        if(!file.setComplexProperties("PICTURE", pictures)) return fail(error, @"この形式ではジャケットを保存できません。");
    }
    return file.save() ? YES : fail(error, @"曲情報をコピーへ書き込めませんでした。");
}
@end
