/*
 *  Copyright (c) 2013, Alun Bestor (alun.bestor@gmail.com)
 *  All rights reserved.
 *
 *  Redistribution and use in source and binary forms, with or without modification,
 *  are permitted provided that the following conditions are met:
 *
 *		Redistributions of source code must retain the above copyright notice, this
 *	    list of conditions and the following disclaimer.
 *
 *		Redistributions in binary form must reproduce the above copyright notice,
 *	    this list of conditions and the following disclaimer in the documentation
 *      and/or other materials provided with the distribution.
 *
 *	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 *	ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 *	WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 *	IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 *	INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 *	BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
 *	OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 *	WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 *	ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 *	POSSIBILITY OF SUCH DAMAGE.
 */

#import "ADBISOImagePrivate.h"
#import "NSString+ADBPaths.h"

#pragma mark -
#pragma mark Date helper macros

//Converts the digits of an ISO extended date format (e.g. {'1','9','9','0'})
//into a proper integer (e.g. 1990).
int extdate_to_int(uint8_t *digits, int length)
{
    //Convert the unterminated char array to a str
    char buf[5];
    strncpy(buf, (const char *)digits, MIN(length, 4));
    buf[length] = '\0';
    
    //Convert the str to an integer
    return atoi(buf);
}



@implementation ADBISOImage

@synthesize baseURL = _baseURL;
@synthesize volumeName = _volumeName;
@synthesize pathCache = _pathCache;
@synthesize sectorSize = _sectorSize;
@synthesize rawSectorSize = _rawSectorSize;
@synthesize leadInSize = _leadInSize;

+ (NSDate *) _dateFromDateTime: (ADBISODateTime)dateTime
{
    struct tm timeStruct;
    timeStruct.tm_year     = dateTime.year;
    timeStruct.tm_mon      = dateTime.month - 1;
    timeStruct.tm_mday     = dateTime.day;
    timeStruct.tm_hour     = dateTime.hour;
    timeStruct.tm_min      = dateTime.minute;
    timeStruct.tm_sec      = dateTime.second;
    timeStruct.tm_gmtoff   = dateTime.gmtOffset * 15 * 60;
    
    time_t epochtime = mktime(&timeStruct);
    
    return [NSDate dateWithTimeIntervalSince1970: epochtime];
}

+ (NSDate *) _dateFromExtendedDateTime: (ADBISOExtendedDateTime)dateTime
{
    struct tm timeStruct;
    timeStruct.tm_year     = extdate_to_int(dateTime.year, 4);
    timeStruct.tm_mon      = extdate_to_int(dateTime.month, 2) - 1;
    timeStruct.tm_mday     = extdate_to_int(dateTime.day, 2);
    timeStruct.tm_hour     = extdate_to_int(dateTime.hour, 2);
    timeStruct.tm_min      = extdate_to_int(dateTime.minute, 2);
    timeStruct.tm_sec      = extdate_to_int(dateTime.second, 2);
    timeStruct.tm_gmtoff   = dateTime.gmtOffset * 15 * 60;
    
    time_t epochtime = mktime(&timeStruct);
    
    return [NSDate dateWithTimeIntervalSince1970: epochtime];
}


#pragma mark - Initalization and cleanup

+ (id) imageWithContentsOfURL: (NSURL *)URL
                        error: (NSError **)outError
{
    return [[(ADBISOImage *)[self alloc] initWithContentsOfURL: URL error: outError] autorelease];
}

- (id) init
{
    self = [super init];
    if (self)
    {
        _sectorSize = ADBISODefaultSectorSize;
        _rawSectorSize = ADBISODefaultSectorSize;
        _leadInSize = ADBISOLeadInSize;
    }
    return self;
}

- (id) initWithContentsOfURL: (NSURL *)URL
                       error: (NSError **)outError
{
    self = [self init];
    if (self)
    {
        BOOL loaded = [self _loadImageAtURL: URL error: outError];
        if (!loaded)
        {
            [self release];
            self = nil;
        }
    }
    return self;
}

- (void) dealloc
{
    if (_handle)
    {
        fclose(_handle);
        _handle = NULL;
    }
    
    self.baseURL = nil;
    self.volumeName = nil;
    self.pathCache = nil;
    [super dealloc];
}


#pragma mark - Path-based API

- (BOOL) fileExistsAtPath: (NSString *)path isDirectory: (BOOL *)isDir
{
    ADBISOFileEntry *entry = [self _fileEntryAtPath: path error: NULL];
    if (entry)
    {
        if (isDir)
            *isDir = entry.isDirectory;
        return YES;
    }
    else
    {
        if (isDir)
            *isDir = NO;
        return NO;
    }
}

- (NSDictionary *) attributesOfFileAtPath: (NSString *)path
                                    error: (out NSError **)outError
{
    ADBISOFileEntry *entry = [self _fileEntryAtPath: path error: outError];
    return entry.attributes;
}

- (NSData *) contentsOfFileAtPath: (NSString *)path
                            error: (out NSError **)outError
{
    ADBISOFileEntry *entry = [self _fileEntryAtPath: path error: outError];
    
    if (entry.isDirectory)
    {
        if (outError)
        {
            NSDictionary *info = @{ NSFilePathErrorKey: path };
            
            //TODO: check what error Cocoa's own file-read methods produce when you pass them a directory.
            *outError = [NSError errorWithDomain: NSPOSIXErrorDomain
                                            code: EISDIR
                                        userInfo: info];
        }
        return nil;
    }
    return [entry contentsWithError: outError];
}

- (NSError *) _readOnlyVolumeErrorForPath: (NSString *)path
{
    return [NSError errorWithDomain: NSCocoaErrorDomain
                               code: NSFileWriteVolumeReadOnlyError
                           userInfo: @{ NSFilePathErrorKey: path }];
}

- (BOOL) removeItemAtPath: (NSString *)path error: (out NSError **)outError
{
    if (outError)
        *outError = [self _readOnlyVolumeErrorForPath: path];
    return NO;
}

- (BOOL) copyItemAtPath: (NSString *)fromPath toPath: (NSString *)toPath error: (out NSError **)outError
{
    if (outError)
        *outError = [self _readOnlyVolumeErrorForPath: toPath];
    return NO;
}

- (BOOL) moveItemAtPath: (NSString *)fromPath toPath: (NSString *)toPath error: (out NSError **)outError
{
    if (outError)
        *outError = [self _readOnlyVolumeErrorForPath: fromPath];
    return NO;
}

- (BOOL) createDirectoryAtPath: (NSString *)path
   withIntermediateDirectories: (BOOL)createIntermediates
                         error: (out NSError **)outError
{
    if (outError)
        *outError = [self _readOnlyVolumeErrorForPath: path];
    return NO;
}

- (ADBISOEnumerator *) enumeratorAtPath: (NSString *)path
                                options: (NSDirectoryEnumerationOptions)mask
                           errorHandler: (ADBFilesystemPathErrorHandler)errorHandler
{
    return [[[ADBISOEnumerator alloc] initWithPath: path
                                       parentImage: self
                                           options: mask
                                      errorHandler: errorHandler] autorelease];
}


#pragma mark - Low-level filesystem API

- (uint32_t) _rawOffsetForLogicalOffset: (uint32_t)offset
{
    uint32_t sector = [self _sectorForLogicalOffset: offset];
    uint32_t relativeOffset = [self _logicalOffsetWithinSector: offset];
    
    return [self _rawOffsetForSector: sector] + relativeOffset;
}

- (uint32_t) _logicalOffsetForRawOffset: (uint32_t)rawOffset
{
    uint32_t sector = [self _sectorForRawOffset: rawOffset];
    uint32_t relativeOffset = [self _rawOffsetWithinSector: rawOffset];
    
    return [self _logicalOffsetForSector: sector] + relativeOffset;
}

- (uint32_t) _logicalOffsetForSector: (uint32_t)sector
{
    return sector * _sectorSize;
}

- (uint32_t) _sectorForLogicalOffset: (uint32_t)offset
{
    return offset / _sectorSize;
}

- (uint32_t) _rawOffsetForSector: (uint32_t)sector
{
    return (sector * _rawSectorSize) + _leadInSize;
}

- (uint32_t) _sectorForRawOffset: (uint32_t)rawOffset
{
    return (rawOffset - _leadInSize) / _rawSectorSize;
}

- (uint32_t) _logicalOffsetWithinSector: (uint32_t)offset
{
    return offset % _sectorSize;
}

- (uint32_t) _rawOffsetWithinSector: (uint32_t)rawOffset
{
    return (rawOffset - _leadInSize) % _rawSectorSize;
}

- (BOOL) _getBytes: (void *)buffer atLogicalRange: (NSRange)range error: (out NSError **)outError
{
    NSUInteger offset = [self _rawOffsetForLogicalOffset: range.location];
    NSUInteger sectorPadding = _rawSectorSize - _sectorSize;
    
    NSUInteger bytesToRead = range.length;
    NSUInteger bytesRead = 0;
    
    while (bytesRead < bytesToRead)
    {
        //If there is no sector padding then we can read the bytes in one go straight across sector boundaries.
        NSUInteger chunkSize = bytesToRead - bytesRead;
        
        //Otherwise we'll have to read up to the edge of the sector and then skip over the padding to the next sector.
        if (sectorPadding > 0)
        {
            NSUInteger offsetWithinSector = [self _rawOffsetWithinSector: offset];
            NSAssert1(offsetWithinSector < _sectorSize, @"Requested byte offset falls within sector padding: %lu", (unsigned long)offset);
            
            chunkSize = MIN(chunkSize, _sectorSize - offsetWithinSector);
        }
        
        BOOL seeked = (fseek(_handle, offset, SEEK_SET) == 0);
        if (!seeked)
        {
            if (outError)
            {
                NSInteger errorCode = errno;
                NSDictionary *info = @{ NSURLErrorKey: self.baseURL };
                *outError = [NSError errorWithDomain: NSPOSIXErrorDomain
                                                code: errorCode
                                            userInfo: info];
            }
            return NO;
        }
        
        void *bufferOffset = &buffer[bytesRead];
        size_t bytesReadInChunk = fread(bufferOffset, 1, chunkSize, _handle);
        if (bytesReadInChunk < chunkSize)
        {
            if (outError)
            {
                NSDictionary *info = @{ NSURLErrorKey: self.baseURL };
                NSInteger errorCode = ferror(_handle);
                
                //We encountered an honest-to-god POSIX error occurred while reading
                if (errorCode != 0)
                {
                    *outError = [NSError errorWithDomain: NSPOSIXErrorDomain
                                                    code: errorCode
                                                userInfo: info];
                }
                //We didn't receive as many bytes as we were expecting, indicating a truncated file
                if (feof(_handle))
                {
                    *outError = [NSError errorWithDomain: NSCocoaErrorDomain
                                                    code: NSFileReadCorruptFileError
                                                userInfo: info];
                }
                
            }
            return NO;
        }
        
        bytesRead += bytesReadInChunk;
        
        //If we still have bytes remaining after this chunk, then we must be at the edge of a sector:
        //Jump across into the next sector and continue.
        if (bytesRead < bytesToRead)
        {
            offset += chunkSize + sectorPadding;
        }
    }
    return YES;
}

- (NSData *) _dataInRange: (NSRange)range error: (out NSError **)outError;
{
    NSMutableData *data = [[NSMutableData alloc] initWithLength: range.length];
    BOOL populated = [self _getBytes: data.mutableBytes atLogicalRange: range error: outError];
    
    if (populated)
    {
        return [data autorelease];
    }
    else
    {
        [data release];
        return nil;
    }
}

- (BOOL) _loadImageAtURL: (NSURL *)URL
                   error: (NSError **)outError
{
    self.baseURL = URL;
    
    _handle = fopen(URL.path.fileSystemRepresentation, "r");
    
    //If the image couldn't be opened for reading, bail out now
    if (!_handle)
    {
        if (outError)
        {
            NSInteger posixError = errno;
            NSDictionary *info = @{ NSURLErrorKey: URL };
            *outError = [NSError errorWithDomain: NSPOSIXErrorDomain code: posixError userInfo: info];
        }
        return NO;
    }
    
    //Search the volume descriptors to find the primary descriptor
    ADBISOPrimaryVolumeDescriptor descriptor;
    
    BOOL foundDescriptor = [self _getPrimaryVolumeDescriptor: &descriptor
                                                       error: outError];
    if (!foundDescriptor) return NO;
    
    //Sanity check: if the string "CD001" is present in the identifier of the primary volume descriptor,
    //we can be pretty sure we have a real ISO on our hands and didn't just get this far by chance thanks
    //to a junk file.
    BOOL identifierFound = bcmp(descriptor.identifier, "CD001", 5) == 0;
    if (!identifierFound)
    {
        if (outError)
        {
            NSDictionary *info = @{ NSURLErrorKey: URL };
            *outError = [NSError errorWithDomain: NSCocoaErrorDomain code: NSFileReadCorruptFileError userInfo: info];
        }
        return NO;
    }
    
    //If we got this far, then we succeeded in loading the image. Hurrah!
    //Get on with parsing out whatever other info interests us from the primary volume descriptor.
    
    self.volumeName = [[[NSString alloc] initWithBytes: descriptor.volumeID
                                                length: ADBISOVolumeIdentifierLength
                                              encoding: NSASCIIStringEncoding] autorelease];
    
    //Prepare the path cache starting with the root directory file entry.
    ADBISODirectoryRecord rootDirectoryRecord;
    memcpy(&rootDirectoryRecord, &descriptor.rootDirectoryRecord, ADBISORootDirectoryRecordLength);
    ADBISOFileEntry *rootDirectory = [ADBISOFileEntry entryFromDirectoryRecord: rootDirectoryRecord inImage: self];
    
    self.pathCache = [NSMutableDictionary dictionaryWithObject: rootDirectory forKey: @"/"];
    
    return YES;
}

- (BOOL) _getPrimaryVolumeDescriptor: (ADBISOPrimaryVolumeDescriptor *)descriptor
                               error: (NSError **)outError
{
    //Start off at the beginning of the ISO's header, 16 sectors into the file.
    NSUInteger sectorIndex = ADBISOVolumeDescriptorSectorOffset;
    
    //Walk through the header of the ISO volume looking for the sector that contains
    //the primary volume descriptor. Each volume descriptor occupies an entire sector,
    //and the type of the descriptor is marked by the starting byte.
    while (YES)
    {
        uint8_t type;
        NSUInteger offset = [self _logicalOffsetForSector: sectorIndex];
        
        NSRange descriptorTypeRange = NSMakeRange(offset, sizeof(uint8_t));
        BOOL readType = [self _getBytes: &type atLogicalRange: descriptorTypeRange error: outError];
        //Bail out if there was a read error or we hit the end of the file
        //(_getBytes:range:error: will have populated outError with the reason.)
        if (!readType)
            return NO;
        
        //We found the primary descriptor, read in the whole thing.
        if (type == ADBISOVolumeDescriptorTypePrimary)
        {
            NSRange descriptorRange = NSMakeRange(offset, sizeof(ADBISOPrimaryVolumeDescriptor));
            return [self _getBytes: descriptor atLogicalRange: descriptorRange error: outError];
        }
        //If we hit the end of the descriptors without finding a primary volume descriptor,
        //this indicates an invalid/incomplete ISO image.
        else if (type == ADBISOVolumeDescriptorTypeSetTerminator)
        {
            if (outError)
            {
                NSDictionary *info = @{ NSURLErrorKey: self.baseURL };
                *outError = [NSError errorWithDomain: NSCocoaErrorDomain
                                                code: NSFileReadCorruptFileError
                                            userInfo: info];
            }
            return NO;
        }
        
        sectorIndex += 1;
    }
}

- (ADBISOFileEntry *) _fileEntryAtPath: (NSString *)path
                                 error: (out NSError **)outError
{
    //IMPLEMENTATION NOTE: should we uppercase files for saner comparison?
    //The ISO-9660 format mandates that filenames can only contain uppercase characters,
    //but some nonstandard ISOs contain lowercase filenames which can cause problems for
    //file lookups.
    
    NSAssert1(path != nil, @"No path provided to %@.", NSStringFromSelector(_cmd));
    
    //Normalize the path to be rooted in the root directory.
    if (![path hasPrefix: @"/"])
        path = [NSString stringWithFormat: @"/%@", path];
    
    //If the path ends in a slash, strip it off - our paths are cached without trailing slashes.
    if (path.length > 1 && [path hasSuffix: @"/"])
        path = [path substringToIndex: path.length - 1];
    
    //If we have a matching entry for this path, return it immediately.
    ADBISOFileEntry *matchingEntry = [self.pathCache objectForKey: path];
    
    //Otherwise, walk backwards through the parent directories looking for one that is in the cache.
    //Once we find one, add its children to the cache under their respective paths: and so on back up
    //to the originally requsted path.
    if (!matchingEntry)
    {
        NSString *parentPath = path.stringByDeletingLastPathComponent;
        if (![parentPath isEqualToString: path])
        {
            //Note recursion.
            ADBISODirectoryEntry *parentEntry = (ADBISODirectoryEntry *)[self _fileEntryAtPath: parentPath error: outError];
            
            //If our parent is a file, not a directory, then we'll fail out without a matching entry.
            if (parentEntry != (id)[NSNull null] && parentEntry.isDirectory)
            {   
                NSArray *siblingEntries = [parentEntry subentriesWithError: outError];
                if (!siblingEntries)
                    return nil;
                
                //Add the siblings into the cache and pluck out the one that matches us, if any
                for (ADBISOFileEntry *sibling in siblingEntries)
                {
                    NSString *siblingPath = [parentPath stringByAppendingPathComponent: sibling.fileName];
                    [self.pathCache setObject: sibling forKey: siblingPath];
                    
                    if ([siblingPath isEqualToString: path])
                        matchingEntry = sibling;
                }
            }
        }
    }
    
    if (matchingEntry && matchingEntry != (id)[NSNull null])
    {
        return matchingEntry;
    }
    else
    {
        //If no matching entry was found, record a null in the table so that we don't have to do an expensive
        //lookup again for something we know isn't there.
        if (!matchingEntry)
        {
            [self.pathCache setObject: [NSNull null] forKey: path];
        }
        
        if (outError)
        {
            NSDictionary *info = @{ NSFilePathErrorKey: path };
            *outError = [NSError errorWithDomain: NSCocoaErrorDomain code: NSFileNoSuchFileError userInfo: info];
        }
        return nil;
    }
}

- (ADBISOFileEntry *) _fileEntryAtOffset: (uint32_t)byteOffset error: (out NSError **)outError
{
    //The record size is the first byte of the file entry, which tells us how many bytes in total to parse in for the entry.
    uint8_t recordSize;
    BOOL gotRecordSize = [self _getBytes: &recordSize atLogicalRange: NSMakeRange(byteOffset, sizeof(uint8_t)) error: outError];
    if (gotRecordSize)
    {
        //Reported record size was too small, this may indicate a corrupt file record.
        if (recordSize < ADBISODirectoryRecordMinLength)
        {
            if (outError)
            {
                NSDictionary *info = @{ NSURLErrorKey: self.baseURL };
                *outError = [NSError errorWithDomain: NSCocoaErrorDomain code: NSFileReadCorruptFileError userInfo: info];
            }
            return nil;
        }
            
        NSRange recordRange = NSMakeRange(byteOffset, recordSize);
        ADBISODirectoryRecord record;
        
        BOOL succeeded = [self _getBytes: &record atLogicalRange: recordRange error: outError];
        if (succeeded)
        {
            return [ADBISOFileEntry entryFromDirectoryRecord: record
                                                     inImage: self];
        }
        else return nil;
    }
    else return nil;
}

- (NSArray *) _fileEntriesInRange: (NSRange)range error: (out NSError **)outError
{
    NSUInteger offset = range.location;
    NSUInteger bytesToRead = range.length;
    NSUInteger readBytes = 0;
    
    NSMutableArray *entries = [NSMutableArray array];
    while (readBytes < bytesToRead)
    {
        NSUInteger offsetWithinSector = [self _logicalOffsetWithinSector: offset];
        NSUInteger bytesRemainingInSector = _sectorSize - offsetWithinSector;
        
        BOOL skipToNextSector = NO;
        
        //If there's not enough space remaining in the sector to fit another entry in, automatically skip to the next sector.
        //CHECKME: are there any non-standard ISOs that span directory records across sector boundaries?
        if (bytesRemainingInSector < ADBISODirectoryRecordMinLength)
        {
            skipToNextSector = YES;
        }
        //Otherwise, check how long the next record is reported to be.
        else
        {
            uint8_t recordSize = 0;
            BOOL gotRecordSize = [self _getBytes: &recordSize atLogicalRange: NSMakeRange(offset, sizeof(uint8_t)) error: outError];
            if (!gotRecordSize)
            {
                return nil;
            }
            
            //Check the reported size of the next record. If it's zero, this should mean we've hit the
            //zeroed-out region at the end of a sector that didn't have enough space to accommodate another record.
            if (recordSize == 0)
            {
                skipToNextSector = YES;
            }
            
            //If the record indicates it would go over the end of the sector, treat this as a malformed record.
            else if (recordSize > bytesRemainingInSector)
            {
                if (outError)
                {
                    NSDictionary *info = @{ NSURLErrorKey: self.baseURL };
                    *outError = [NSError errorWithDomain: NSCocoaErrorDomain code: NSFileReadCorruptFileError userInfo: info];
                }
                return nil;
            }
            
            //Otherwise, keep reading the rest of the record data from this sector.
            else
            {
                ADBISODirectoryRecord record;
                NSRange recordRange = NSMakeRange(offset, recordSize);
                BOOL retrievedRecord = [self _getBytes: &record atLogicalRange: recordRange error: outError];
                if (retrievedRecord)
                {
                    ADBISOFileEntry *entry = [ADBISOFileEntry entryFromDirectoryRecord: record inImage: self];
                    [entries addObject: entry];
                    
                    offset += recordSize;
                    readBytes += recordSize;
                }
                else
                {
                    return nil;
                }
            }
        }
        
        if (skipToNextSector)
        {
            readBytes += bytesRemainingInSector;
            offset += bytesRemainingInSector;
        }
    }
    
    return entries;
}

@end



@implementation ADBISOFileEntry
@synthesize fileName = _fileName;
@synthesize version = _version;
@synthesize creationDate = _creationDate;
@synthesize parentImage = _parentImage;
@synthesize hidden = _hidden;

+ (id) entryFromDirectoryRecord: (ADBISODirectoryRecord)record
                        inImage: (ADBISOImage *)image
{
    BOOL isDirectory = (record.fileFlags & ADBISOFileIsDirectory);
    Class entryClass = isDirectory ? [ADBISODirectoryEntry class] : [ADBISOFileEntry class];
    return [[[entryClass alloc] initWithDirectoryRecord: record inImage: image] autorelease];
}

- (id) initWithDirectoryRecord: (ADBISODirectoryRecord)record
                       inImage: (ADBISOImage *)image
{
    self = [self init];
    if (self)
    {
        //Note: just assignment, not copying, as our parent image may cache
        //file entries and that would result in a retain cycle.
        self.parentImage = image;
        
        //If this record has extended attributes, they will be recorded at the start of the file extent
        //and the actual file data will be shoved into the next sector beyond this.
        NSUInteger numExtendedAttributeSectors = 0;
        if (record.extendedAttributeLength > 0)
            numExtendedAttributeSectors = ceilf(record.extendedAttributeLength / (float)image.sectorSize);
            
#if defined(__BIG_ENDIAN__)
        _dataRange.location    = (NSUInteger)[image _logicalOffsetForSector: record.extentLBALocationBigEndian + numExtendedAttributeSectors];
        _dataRange.length      = record.extentDataLengthBigEndian;
#else
        _dataRange.location    = (NSUInteger)[image _logicalOffsetForSector: record.extentLBALocationLittleEndian + numExtendedAttributeSectors];
        _dataRange.length      = record.extentDataLengthLittleEndian;
#endif
        
        if (record.identifierLength == 0)
            self.fileName = @""; //Should never occur
        else if (record.identifierLength == 1 && record.identifier[0] == '\0')
            self.fileName = @".";
        else if (record.identifierLength == 1 && record.identifier[0] == '\1')
            self.fileName = @"..";
        else
        {
            NSString *identifier = [[NSString alloc] initWithBytes: record.identifier
                                                            length: record.identifierLength
                                                          encoding: NSASCIIStringEncoding];
            
            if (self.isDirectory)
            {
                self.fileName = identifier;
            }
            else
            {
                //ISO9660 filenames are stored in the format "FILENAME.EXE;1",
                //where the last component marks the version number of the file.
                NSArray *identifierComponents = [identifier componentsSeparatedByString: @";"];
                
                self.fileName   = [identifierComponents objectAtIndex: 0];
                
                //Some ISOs dispense with the version number altogether,
                //even though it's required by the spec.
                if (identifierComponents.count > 1)
                {
                    self.version = [(NSString *)[identifierComponents objectAtIndex: 1] integerValue];
                }
                else
                {
                    self.version = 1;
                }
                
                //Under ISO9660 spec, filenames will always have a file-extension dot even
                //if they have no extension. Strip off the trailing dot now.
                //CONFIRM: is this consistent with what ISO9660 consumers expect?
                if ([self.fileName hasSuffix: @"."])
                    self.fileName = self.fileName.stringByDeletingPathExtension;
            }
            
            [identifier release];
        }
        
        self.creationDate = [ADBISOImage _dateFromDateTime: record.recordingTime];
        self.hidden = (record.fileFlags & ADBISOFileIsHidden) == ADBISOFileIsHidden;
    }
    return self;
}

- (void) dealloc
{
    self.fileName = nil;
    self.creationDate = nil;
    
    [super dealloc];
}

- (BOOL) isDirectory
{
    return NO;
}

- (uint32_t) fileSize
{
    return _dataRange.length;
}

- (NSData *) contentsWithError: (NSError **)outError
{
    return [self.parentImage _dataInRange: _dataRange error: outError];
}

- (NSDictionary *) attributes
{
    NSDictionary *attrs = @{
                            NSFileType: (self.isDirectory ? NSFileTypeDirectory : NSFileTypeRegular),
                            NSFileCreationDate: self.creationDate,
                            NSFileModificationDate: self.creationDate,
                            NSFileSize: @(self.fileSize),
                            };
    return attrs;
}

- (NSString *) description
{
    return [NSString stringWithFormat: @"%@ (%@)", self.class, self.fileName];
}

@end


@implementation ADBISODirectoryEntry
@synthesize cachedSubentries = _cachedSubentries;

- (void) dealloc
{
    self.cachedSubentries = nil;
    [super dealloc];
}

- (BOOL) isDirectory
{
    return YES;
}

- (NSArray *) subentriesWithError: (out NSError **)outError
{
    //Populate the records the first time they are needed.
    if (!self.cachedSubentries)
    {
        NSArray *subEntries = [self.parentImage _fileEntriesInRange: _dataRange error: outError];
        if (subEntries)
        {
            //Filter the entries to eliminate older versions of the same filename,
            //and to strip out . and .. entries.
            NSMutableDictionary *subentriesByFilename = [NSMutableDictionary dictionaryWithCapacity: subEntries.count];
            for (ADBISOFileEntry *entry in subEntries)
            {
                if ([entry.fileName isEqualToString: @"."] || [entry.fileName isEqualToString: @".."])
                {
                    continue;
                }
                
                //Strip out older versions of files, preserving only the latest recorded versions.
                ADBISOFileEntry *existingEntry = [subentriesByFilename objectForKey: entry.fileName];
                if (!existingEntry || existingEntry.version < entry.version)
                    [subentriesByFilename setObject: entry forKey: entry.fileName];
            }
            
            //The ISO will have (should have) ordered the entries by filename, but our NSDictionary
            //will have mixed them up again. Sort them again as a courtesy.
            NSComparator sortByFilename = ^NSComparisonResult(ADBISOFileEntry *file1, ADBISOFileEntry *file2) {
                return [file1.fileName caseInsensitiveCompare: file2.fileName];
            };
            self.cachedSubentries = [subentriesByFilename.allValues sortedArrayUsingComparator: sortByFilename];
        }
    }
    
    return self.cachedSubentries;
}

- (NSData *) contentsWithError: (NSError **)outError
{
    NSAssert(NO, @"Attempted to retrieve contents of directory.");
    return nil;
}

@end


@implementation ADBISOEnumerator
@synthesize parentImage = _parentImage;
@synthesize treePositions = _treePositions;
@synthesize tree = _tree;
@synthesize currentDirectoryPath = _currentDirectoryPath;
@synthesize currentEntry = _currentEntry;
@synthesize errorHandler = _errorHandler;
@synthesize enumerationOptions = _enumerationOptions;

- (id) initWithPath: (NSString *)path
        parentImage: (ADBISOImage *)image
            options: (NSDirectoryEnumerationOptions)enumerationOptions
       errorHandler: (ADBFilesystemPathErrorHandler)errorHandler
{
    self = [self init];
    if (self)
    {
        NSError *error;
        ADBISODirectoryEntry *entryAtPath = (ADBISODirectoryEntry *)[image _fileEntryAtPath: path error: &error];
        if (entryAtPath)
        {
            if (entryAtPath.isDirectory)
            {
                NSArray *subpaths = [entryAtPath subentriesWithError: &error];
                if (subpaths)
                {
                    //Start the enumerator off at the first file entry within this directory.
                    self.tree = [NSMutableArray arrayWithObject: subpaths];
                    self.treePositions = [NSIndexPath indexPathWithIndex: 0];
                    
                    self.currentDirectoryPath = path;
                    self.parentImage = image;
                    _enumerationOptions = enumerationOptions;
                }
                else
                {
                    if (errorHandler)
                    {
                        //TODO: should we check the return value, and 'continue' with an exhausted enumerator
                        //if the error handler returns YES? What does NSDirectoryEnumerator do in this case?
                        errorHandler(path, error);
                    }
                    
                    [self release];
                    self = nil;
                }
            }
            //User tried to enumerate a file: return an empty enumerator
            //(this behaviour is consistent with NSFileManager enumeratorAtPath:.) 
            else
            {
                _exhausted = YES;
            }
        }
        else
        {
            if (errorHandler)
            {
                //TODO: should we check the return value, and 'continue' with an exhausted enumerator
                //if the error handler returns YES? What does NSDirectoryEnumerator do in this case?
                errorHandler(path, error);
            }
            
            [self release];
            self = nil;
        }
    }
    return self;
}

- (void) dealloc
{
    self.parentImage = nil;
    self.treePositions = nil;
    self.tree = nil;
    self.currentDirectoryPath = nil;
    self.currentEntry = nil;
    self.errorHandler = nil;
    
    [super dealloc];
}

- (id <ADBFilesystemPathAccess>) filesystem
{
    return self.parentImage;
}

- (NSDictionary *) fileAttributes
{
    return self.currentEntry.attributes;
}

- (id) nextObject
{
    if (_exhausted)
        return nil;
    
    while (YES)
    {
        NSUInteger currentLevel = self.treePositions.length - 1;
        NSArray *currentDirectory = [self.tree objectAtIndex: currentLevel];
        NSUInteger currentIndex = [self.treePositions indexAtPosition: currentLevel];
        NSAssert2(currentIndex != NSNotFound, @"Tree positions %@ out of sync with tree %@.", self.treePositions, self.tree);
        
        //If we're within the bounds of this directory, return the next file entry.
        if (currentIndex < currentDirectory.count)
        {
            self.currentEntry = [currentDirectory objectAtIndex: currentIndex];
            
            if ((_enumerationOptions & NSDirectoryEnumerationSkipsHiddenFiles) && self.currentEntry.isHidden)
            {
                self.treePositions = [[self.treePositions indexPathByRemovingLastIndex] indexPathByAddingIndex: currentIndex + 1];
                continue;
            }
            else
            {
                NSString *currentEntryPath = [self.currentDirectoryPath stringByAppendingPathComponent: self.currentEntry.fileName];
                
                BOOL isDir = self.currentEntry.isDirectory;
                
                //If this file entry is a subdirectory and we've already returned its base path,
                //then descend into the subdirectory and return the first result within.
                if (isDir && _hasReturnedDirectory)
                {
                    _hasReturnedDirectory = NO;
                    
                    //Bump the index for this level of the tree before descending, so that when
                    //we return from this subdirectory we'll move on to the next element.
                    self.treePositions = [[self.treePositions indexPathByRemovingLastIndex] indexPathByAddingIndex: currentIndex + 1];
                    
                    if (!_skipDescendants && !(_enumerationOptions & NSDirectoryEnumerationSkipsSubdirectoryDescendants))
                    {
                        NSError *error;
                        NSArray *subpaths = [(ADBISODirectoryEntry *)self.currentEntry subentriesWithError: &error];
                        if (subpaths.count)
                        {
                            [self.tree addObject: subpaths];
                            self.treePositions = [self.treePositions indexPathByAddingIndex: 0];
                            self.currentDirectoryPath = currentEntryPath;
                            
                            //Loop around and begin enumerating the new subdirectory.
                            continue;
                        }
                        else if (!subpaths)
                        {
                            BOOL shouldContinue = NO;
                            if (self.errorHandler)
                            {
                                shouldContinue = self.errorHandler(currentEntryPath, error);
                            }
                            
                            //If the error handler says it's ok to continue after this error,
                            //then go ahead and enumerate the next path. Otherwise, fail out.
                            if (shouldContinue)
                            {
                                continue;
                            }
                            else
                            {
                                self.currentEntry = nil;
                                return nil;
                            }
                        }
                    }
                    else
                    {
                        _skipDescendants = NO;
                    }
                }
                else
                {
                    NSAssert(_hasReturnedDirectory == NO, @"Somehow got here with _hasReturnedDirectory flag still active.");
                    _skipDescendants = NO;
                    
                    //If this is a directory, flag that we've returned its path but keep the index pointed at it
                    //so that on the next iteration we'll descend into it.
                    if (isDir)
                    {
                        _hasReturnedDirectory = YES;
                    }
                    //Otherwise, move on to the next entry next time.
                    else
                    {
                        self.treePositions = [[self.treePositions indexPathByRemovingLastIndex] indexPathByAddingIndex: currentIndex + 1];
                    }
                    
                    return currentEntryPath;
                }
            }
        }
        
        //If we've run out of entries in this subdirectory, drop one level back and continue the enumeration.
        else if (currentLevel > 0)
        {
            [self.tree removeLastObject];
            self.treePositions = self.treePositions.indexPathByRemovingLastIndex;
            self.currentDirectoryPath = self.currentDirectoryPath.stringByDeletingLastPathComponent;
            
            continue;
        }
        
        //If we're already back at the root directory and have no more entries, then stop enumerating altogether.
        else
        {
            _exhausted = YES;
            self.currentEntry = nil;
            return nil;
        }
    }
}

- (NSUInteger) level
{
    //TODO: confirm that NSDirectoryEnumerator returns 1 for items in the base directory
    return self.treePositions.length;
}

- (void) skipDescendants
{
    _skipDescendants = YES;
}

@end