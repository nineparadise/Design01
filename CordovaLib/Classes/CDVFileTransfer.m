/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDV.h"

#import <AssetsLibrary/ALAsset.h>
#import <AssetsLibrary/ALAssetRepresentation.h>
#import <AssetsLibrary/ALAssetsLibrary.h>
#import <CFNetwork/CFNetwork.h>

@interface CDVFileTransfer ()
// Sets the requests headers for the request.
- (void)applyRequestHeaders:(NSDictionary*)headers toRequest:(NSMutableURLRequest*)req;
// Creates a delegate to handle an upload.
- (CDVFileTransferDelegate*)delegateForUploadCommand:(CDVInvokedUrlCommand*)command;
// Creates an NSData* for the file for the given upload arguments.
- (void)fileDataForUploadCommand:(CDVInvokedUrlCommand*)command;
@end

// Buffer size to use for streaming uploads.
static const NSUInteger kStreamBufferSize = 32768;
// Magic value within the options dict used to set a cookie.
NSString* const kOptionsKeyCookie = @"__cookie";
// Form boundary for multi-part requests.

NSString* const kFormBoundary = @"END_PART";

// Writes the given data to the stream in a blocking way.
// If successful, returns bytesToWrite.
// If the stream was closed on the other end, returns 0.
// If there was an error, returns -1.
static CFIndex WriteDataToStream(NSData* data, CFWriteStreamRef stream)
{
    UInt8* bytes = (UInt8*)[data bytes];
    NSUInteger bytesToWrite = [data length];
    NSUInteger totalBytesWritten = 0;

    while (totalBytesWritten < bytesToWrite) {
        CFIndex result = CFWriteStreamWrite(stream,
                bytes + totalBytesWritten,
                bytesToWrite - totalBytesWritten);
        if (result < 0) {
            CFStreamError error = CFWriteStreamGetError(stream);
            NSLog(@"WriteStreamError domain: %ld error: %ld", error.domain, error.error);
            return result;
        } else if (result == 0) {
            return result;
        }
        totalBytesWritten += result;
    }

    return totalBytesWritten;
}

@implementation CDVFileTransfer
@synthesize activeTransfers;

- (NSString*)escapePathComponentForUrlString:(NSString*)urlString
{
    NSRange schemeAndHostRange = [urlString rangeOfString:@"://.*?/" options:NSRegularExpressionSearch];

    if (schemeAndHostRange.length == 0) {
        return urlString;
    }

    NSInteger schemeAndHostEndIndex = NSMaxRange(schemeAndHostRange);
    NSString* schemeAndHost = [urlString substringToIndex:schemeAndHostEndIndex];
    NSString* pathComponent = [urlString substringFromIndex:schemeAndHostEndIndex];
    pathComponent = [pathComponent stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

    return [schemeAndHost stringByAppendingString:pathComponent];
}

- (void)applyRequestHeaders:(NSDictionary*)headers toRequest:(NSMutableURLRequest*)req
{
    [req setValue:@"XMLHttpRequest" forHTTPHeaderField:@"X-Requested-With"];

    NSString* userAgent = [self.commandDelegate userAgent];
    if (userAgent) {
        [req setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    }

    for (NSString* headerName in headers) {
        id value = [headers objectForKey:headerName];
        if (!value || (value == [NSNull null])) {
            value = @"null";
        }

        // First, remove an existing header if one exists.
        [req setValue:nil forHTTPHeaderField:headerName];

        if (![value isKindOfClass:[NSArray class]]) {
            value = [NSArray arrayWithObject:value];
        }

        // Then, append all header values.
        for (id __strong subValue in value) {
            // Convert from an NSNumber -> NSString.
            if ([subValue respondsToSelector:@selector(stringValue)]) {
                subValue = [subValue stringValue];
            }
            if ([subValue isKindOfClass:[NSString class]]) {
                [req addValue:subValue forHTTPHeaderField:headerName];
            }
        }
    }
}

- (NSURLRequest*)requestForUploadCommand:(CDVInvokedUrlCommand*)command fileData:(NSData*)fileData
{
    // arguments order from js: [filePath, server, fileKey, fileName, mimeType, params, debug, chunkedMode]
    // however, params is a JavaScript object and during marshalling is put into the options dict,
    // thus debug and chunkedMode are the 6th and 7th arguments
    NSArray* arguments = command.arguments;
    NSString* target = (NSString*)[arguments objectAtIndex:0];
    NSString* server = (NSString*)[arguments objectAtIndex:1];
    NSString* fileKey = [arguments objectAtIndex:2 withDefault:@"file"];
    NSString* fileName = [arguments objectAtIndex:3 withDefault:@"no-filename"];
    NSString* mimeType = [arguments objectAtIndex:4 withDefault:nil];
    NSDictionary* options = [arguments objectAtIndex:5 withDefault:nil];
    //    BOOL trustAllHosts = [[arguments objectAtIndex:6 withDefault:[NSNumber numberWithBool:YES]] boolValue]; // allow self-signed certs
    BOOL chunkedMode = [[arguments objectAtIndex:7 withDefault:[NSNumber numberWithBool:YES]] boolValue];
    NSDictionary* headers = [arguments objectAtIndex:8 withDefault:nil];
    //NSString* Token = [arguments objectAtIndex:9 withDefault:nil];

    CDVPluginResult* result = nil;
    CDVFileTransferError errorCode = 0;

    // NSURL does not accepts URLs with spaces in the path. We escape the path in order
    // to be more lenient.
    NSURL* url = [NSURL URLWithString:server];
    DLog("Token is : %@",options);

    if (!url) {
        errorCode = INVALID_URL_ERR;
        NSLog(@"File Transfer Error: Invalid server URL %@", server);
    } else if (!fileData) {
        errorCode = FILE_NOT_FOUND_ERR;
    }

    if (errorCode > 0) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self createFileTransferError:errorCode AndSource:target AndTarget:server]];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return nil;
    }

    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:@"POST"];

    //    Magic value to set a cookie
    if ([options objectForKey:kOptionsKeyCookie]) {
        [req setValue:[options objectForKey:kOptionsKeyCookie] forHTTPHeaderField:@"Cookie"];
        [req setHTTPShouldHandleCookies:NO];
    }

    NSString* contentType = [NSString stringWithFormat:@"image/jpeg"];
    [req setValue:contentType forHTTPHeaderField:@"Content-Type"];
    [self applyRequestHeaders:headers toRequest:req];

   // NSData* formBoundaryData = [[NSString stringWithFormat:@"--%@\r\n", kFormBoundary] dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData* postBodyBeforeFile = [NSMutableData data];

   /* for (NSString* key in options) {
        id val = [options objectForKey:key];
        if (!val || (val == [NSNull null]) || [key isEqualToString:kOptionsKeyCookie]) {
            continue;
        }
        // if it responds to stringValue selector (eg NSNumber) get the NSString
        if ([val respondsToSelector:@selector(stringValue)]) {
            val = [val stringValue];
        }
        // finally, check whether it is a NSString (for dataUsingEncoding selector below)
        if (![val isKindOfClass:[NSString class]]) {
            continue;
        }

        [postBodyBeforeFile appendData:formBoundaryData];
        [postBodyBeforeFile appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", key] dataUsingEncoding:NSUTF8StringEncoding]];
        [postBodyBeforeFile appendData:[val dataUsingEncoding:NSUTF8StringEncoding]];
        [postBodyBeforeFile appendData:[@"\r\n" dataUsingEncoding : NSUTF8StringEncoding]];
    }
*/
    //[postBodyBeforeFile appendData:formBoundaryData];
    /*[postBodyBeforeFile appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\n", fileKey, fileName] dataUsingEncoding:NSUTF8StringEncoding]];
    if (mimeType != nil) {
        [postBodyBeforeFile appendData:[[NSString stringWithFormat:@"Content-Type: %@\r\n", mimeType] dataUsingEncoding:NSUTF8StringEncoding]];
    }*/
    [postBodyBeforeFile appendData:[[NSString stringWithFormat:@"Content-Length: %d\r\n\r\n", [fileData length]] dataUsingEncoding:NSUTF8StringEncoding]];
    [postBodyBeforeFile appendData:[[NSString stringWithFormat:@"Slug: %@\r\n\r\n",fileName] dataUsingEncoding:NSUTF8StringEncoding]];

    DLog(@"fileData length: %d", [fileData length]);
   
    NSUInteger totalPayloadLength = [postBodyBeforeFile length] + [fileData length];
    [req setValue:[[NSNumber numberWithInteger:totalPayloadLength] stringValue] forHTTPHeaderField:@"Content-Length"];
   DLog("debug head :  %@",[[NSString alloc] initWithData:postBodyBeforeFile encoding:NSASCIIStringEncoding]);
    if (chunkedMode) {
        CFReadStreamRef readStream = NULL;
        CFWriteStreamRef writeStream = NULL;
        CFStreamCreateBoundPair(NULL, &readStream, &writeStream, kStreamBufferSize);
        [req setHTTPBodyStream:CFBridgingRelease(readStream)];

        [self.commandDelegate runInBackground:^{
            if (CFWriteStreamOpen(writeStream)) {
                NSData* chunks[] = {postBodyBeforeFile, fileData};
                int numChunks = sizeof(chunks) / sizeof(chunks[0]);

                for (int i = 0; i < numChunks; ++i) {
                     
                    CFIndex result = WriteDataToStream(chunks[i], writeStream);
                    if (result <= 0) {
                         
                        break;
                    }
                }
            } else {
                NSLog(@"FileTransfer: Failed to open writeStream");
            }
            
            CFWriteStreamClose(writeStream);
            CFRelease(writeStream);
        }];
    } else {
        [postBodyBeforeFile appendData:fileData];
        DLog("debug head :  %@",[[NSString alloc] initWithData:postBodyBeforeFile encoding:NSASCIIStringEncoding]);

        //[postBodyBeforeFile appendData:postBodyAfterFile];
        [req setHTTPBody:postBodyBeforeFile];
    }
    DLog("debug head :  %@",[[NSString alloc] initWithData:postBodyBeforeFile encoding:NSASCIIStringEncoding]);

    return req;
}

- (CDVFileTransferDelegate*)delegateForUploadCommand:(CDVInvokedUrlCommand*)command
{
    NSString* source = [command.arguments objectAtIndex:0];
    NSString* server = [command.arguments objectAtIndex:1];
    BOOL trustAllHosts = [[command.arguments objectAtIndex:6 withDefault:[NSNumber numberWithBool:YES]] boolValue]; // allow self-signed certs
    NSString* objectId = [command.arguments objectAtIndex:9];

    CDVFileTransferDelegate* delegate = [[CDVFileTransferDelegate alloc] init];

    delegate.command = self;
    delegate.callbackId = command.callbackId;
    delegate.direction = CDV_TRANSFER_UPLOAD;
    delegate.objectId = objectId;
    delegate.source = source;
    delegate.target = server;
    delegate.trustAllHosts = trustAllHosts;

    return delegate;
}

- (void)fileDataForUploadCommand:(CDVInvokedUrlCommand*)command
{
    NSString* target = (NSString*)[command.arguments objectAtIndex:0];
    NSError* __autoreleasing err = nil;

    // return unsupported result for assets-library URLs
    if ([target hasPrefix:kCDVAssetsLibraryPrefix]) {
        // Instead, we return after calling the asynchronous method and send `result` in each of the blocks.
        ALAssetsLibraryAssetForURLResultBlock resultBlock = ^(ALAsset* asset) {
            if (asset) {
                // We have the asset!  Get the data and send it off.
                ALAssetRepresentation* assetRepresentation = [asset defaultRepresentation];
                Byte* buffer = (Byte*)malloc([assetRepresentation size]);
                NSUInteger bufferSize = [assetRepresentation getBytes:buffer fromOffset:0.0 length:[assetRepresentation size] error:nil];
                NSData* fileData = [NSData dataWithBytesNoCopy:buffer length:bufferSize freeWhenDone:YES];
                [self uploadData:fileData command:command];
            } else {
                // We couldn't find the asset.  Send the appropriate error.
                CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsInt:NOT_FOUND_ERR];
                [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            }
        };
        ALAssetsLibraryAccessFailureBlock failureBlock = ^(NSError* error) {
            // Retrieving the asset failed for some reason.  Send the appropriate error.
            CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:[error localizedDescription]];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        };

        ALAssetsLibrary* assetsLibrary = [[ALAssetsLibrary alloc] init];
        [assetsLibrary assetForURL:[NSURL URLWithString:target] resultBlock:resultBlock failureBlock:failureBlock];
        return;
    } else {
        // Extract the path part out of a file: URL.
        NSString* filePath = [target hasPrefix:@"/"] ? [target copy] : [[NSURL URLWithString:target] path];
        if (filePath == nil) {
            // We couldn't find the asset.  Send the appropriate error.
            CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsInt:NOT_FOUND_ERR];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }

        // Memory map the file so that it can be read efficiently even if it is large.
        NSData* fileData = [NSData dataWithContentsOfFile:filePath options:NSDataReadingMappedIfSafe error:&err];

        if (err != nil) {
            NSLog(@"Error opening file %@: %@", target, err);
        }
        [self uploadData:fileData command:command];
    }
}

- (void)upload:(CDVInvokedUrlCommand*)command
{
    // fileData and req are split into helper functions to ease the unit testing of delegateForUpload.
    // First, get the file data.  This method will call `uploadData:command`.
    [self fileDataForUploadCommand:command];
}

- (void)uploadData:(NSData*)fileData command:(CDVInvokedUrlCommand*)command
{
    NSURLRequest* req = [self requestForUploadCommand:command fileData:fileData];

    if (req == nil) {
        return;
    }
    CDVFileTransferDelegate* delegate = [self delegateForUploadCommand:command];
    [NSURLConnection connectionWithRequest:req delegate:delegate];

    if (activeTransfers == nil) {
        activeTransfers = [[NSMutableDictionary alloc] init];
    }

    [activeTransfers setObject:delegate forKey:delegate.objectId];
}

- (void)abort:(CDVInvokedUrlCommand*)command
{
    NSString* objectId = [command.arguments objectAtIndex:0];

    CDVFileTransferDelegate* delegate = [activeTransfers objectForKey:objectId];

    if (delegate != nil) {
        [delegate.connection cancel];
        [activeTransfers removeObjectForKey:objectId];

        // delete uncomplete file
        NSFileManager* fileMgr = [NSFileManager defaultManager];
        [fileMgr removeItemAtPath:delegate.target error:nil];

        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self createFileTransferError:CONNECTION_ABORTED AndSource:delegate.source AndTarget:delegate.target]];
        [self.commandDelegate sendPluginResult:result callbackId:delegate.callbackId];
    }
}

- (void)download:(CDVInvokedUrlCommand*)command
{
    DLog(@"File Transfer downloading file...");
    NSString* sourceUrl = [command.arguments objectAtIndex:0];
    NSString* filePath = [command.arguments objectAtIndex:1];
    BOOL trustAllHosts = [[command.arguments objectAtIndex:2 withDefault:[NSNumber numberWithBool:YES]] boolValue]; // allow self-signed certs
    NSString* objectId = [command.arguments objectAtIndex:3];
    NSDictionary* headers = [command.arguments objectAtIndex:4 withDefault:nil];

    // return unsupported result for assets-library URLs
    if ([filePath hasPrefix:kCDVAssetsLibraryPrefix]) {
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_MALFORMED_URL_EXCEPTION messageAsString:@"download not supported for assets-library URLs."];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    CDVPluginResult* result = nil;
    CDVFileTransferError errorCode = 0;

    NSURL* file;

    if ([filePath hasPrefix:@"/"]) {
        file = [NSURL fileURLWithPath:filePath];
    } else {
        file = [NSURL URLWithString:filePath];
    }

    NSURL* url = [NSURL URLWithString:sourceUrl];

    if (!url) {
        errorCode = INVALID_URL_ERR;
        NSLog(@"File Transfer Error: Invalid server URL %@", sourceUrl);
    } else if (![file isFileURL]) {
        errorCode = FILE_NOT_FOUND_ERR;
        NSLog(@"File Transfer Error: Invalid file path or URL %@", filePath);
    }

    if (errorCode > 0) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self createFileTransferError:errorCode AndSource:sourceUrl AndTarget:filePath]];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:url];
    [self applyRequestHeaders:headers toRequest:req];

    CDVFileTransferDelegate* delegate = [[CDVFileTransferDelegate alloc] init];
    delegate.command = self;
    delegate.direction = CDV_TRANSFER_DOWNLOAD;
    delegate.callbackId = command.callbackId;
    delegate.objectId = objectId;
    delegate.source = sourceUrl;
    delegate.target = filePath;
    delegate.trustAllHosts = trustAllHosts;

    delegate.connection = [NSURLConnection connectionWithRequest:req delegate:delegate];

    if (activeTransfers == nil) {
        activeTransfers = [[NSMutableDictionary alloc] init];
    }

    [activeTransfers setObject:delegate forKey:delegate.objectId];
}

- (NSMutableDictionary*)createFileTransferError:(int)code AndSource:(NSString*)source AndTarget:(NSString*)target
{
    NSMutableDictionary* result = [NSMutableDictionary dictionaryWithCapacity:3];

    [result setObject:[NSNumber numberWithInt:code] forKey:@"code"];
    [result setObject:source forKey:@"source"];
    [result setObject:target forKey:@"target"];
    NSLog(@"FileTransferError %@", result);

    return result;
}

- (NSMutableDictionary*)createFileTransferError:(int)code
                                      AndSource:(NSString*)source
                                      AndTarget:(NSString*)target
                                  AndHttpStatus:(int)httpStatus
                                        AndBody:(NSString*)body
{
    NSMutableDictionary* result = [NSMutableDictionary dictionaryWithCapacity:5];

    [result setObject:[NSNumber numberWithInt:code] forKey:@"code"];
    [result setObject:source forKey:@"source"];
    [result setObject:target forKey:@"target"];
    [result setObject:[NSNumber numberWithInt:httpStatus] forKey:@"http_status"];
    [result setObject:body forKey:@"body"];
    NSLog(@"FileTransferError %@", result);

    return result;
}

- (void)onReset
{
    for (CDVFileTransferDelegate* delegate in [activeTransfers allValues]) {
        [delegate.connection cancel];
    }

    [activeTransfers removeAllObjects];
}

@end

@implementation CDVFileTransferDelegate

@synthesize callbackId, connection, source, target, responseData, command, bytesTransfered, bytesExpected, direction, responseCode, objectId;

- (void)connectionDidFinishLoading:(NSURLConnection*)connection
{
    NSString* uploadResponse = nil;
    NSString* downloadResponse = nil;
    BOOL downloadWriteOK = NO;
    NSMutableDictionary* uploadResult;
    CDVPluginResult* result = nil;
    NSError* __autoreleasing error = nil;
    NSString* parentPath;
    BOOL bDirRequest = NO;
    CDVFile* file;

    NSLog(@"File Transfer Finished with response code %d", self.responseCode);

    if (self.direction == CDV_TRANSFER_UPLOAD) {
        uploadResponse = [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding];

        if ((self.responseCode >= 200) && (self.responseCode < 300)) {
            // create dictionary to return FileUploadResult object
            uploadResult = [NSMutableDictionary dictionaryWithCapacity:3];
            if (uploadResponse != nil) {
                [uploadResult setObject:uploadResponse forKey:@"response"];
            }
            [uploadResult setObject:[NSNumber numberWithInt:self.bytesTransfered] forKey:@"bytesSent"];
            [uploadResult setObject:[NSNumber numberWithInt:self.responseCode] forKey:@"responseCode"];
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:uploadResult];
        } else {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[command createFileTransferError:CONNECTION_ERR AndSource:source AndTarget:target AndHttpStatus:self.responseCode AndBody:uploadResponse]];
        }
    }
    if (self.direction == CDV_TRANSFER_DOWNLOAD) {
        DLog(@"Write file %@", target);
        // error=[[NSError alloc]init];

        if ((self.responseCode >= 200) && (self.responseCode < 300)) {
            @try {
                parentPath = [self.target stringByDeletingLastPathComponent];

                // check if the path exists => create directories if needed
                if (![[NSFileManager defaultManager] fileExistsAtPath:parentPath]) {
                    [[NSFileManager defaultManager] createDirectoryAtPath:parentPath withIntermediateDirectories:YES attributes:nil error:nil];
                }

                downloadWriteOK = [self.responseData writeToFile:self.target options:NSDataWritingFileProtectionNone error:&error];

                if (downloadWriteOK == NO) {
                    // send our results back
                    downloadResponse = [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding];
                    result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[command createFileTransferError:INVALID_URL_ERR AndSource:source AndTarget:target AndHttpStatus:self.responseCode AndBody:downloadResponse]];
                } else {
                    DLog(@"File Transfer Download success");

                    file = [[CDVFile alloc] init];

                    result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:[file getDirectoryEntry:target isDirectory:bDirRequest]];
                }
            }
            @catch(id exception) {
                // jump back to main thread
                downloadResponse = [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding];
                result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsDictionary:[command createFileTransferError:FILE_NOT_FOUND_ERR AndSource:source AndTarget:target AndHttpStatus:self.responseCode AndBody:downloadResponse]];
            }
        } else {
            downloadResponse = [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding];

            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[command createFileTransferError:CONNECTION_ERR AndSource:source AndTarget:target AndHttpStatus:self.responseCode AndBody:downloadResponse]];
        }
    }

    [self.command.commandDelegate sendPluginResult:result callbackId:callbackId];

    // remove connection for activeTransfers
    [command.activeTransfers removeObjectForKey:objectId];
}

- (void)connection:(NSURLConnection*)connection didReceiveResponse:(NSURLResponse*)response
{
    self.mimeType = [response MIMEType];

    // required for iOS 4.3, for some reason; response is
    // a plain NSURLResponse, not the HTTP subclass
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;

        self.responseCode = [httpResponse statusCode];
        self.bytesExpected = [response expectedContentLength];
    } else if ([response.URL isFileURL]) {
        NSDictionary* attr = [[NSFileManager defaultManager] attributesOfItemAtPath:[response.URL path] error:nil];
        self.responseCode = 200;
        self.bytesExpected = [attr[NSFileSize] longLongValue];
    } else {
        self.responseCode = 200;
        self.bytesExpected = NSURLResponseUnknownLength;
    }
}

- (void)connection:(NSURLConnection*)connection didFailWithError:(NSError*)error
{
    NSString* body = [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding];
    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[command createFileTransferError:CONNECTION_ERR AndSource:source AndTarget:target AndHttpStatus:self.responseCode AndBody:body]];

    NSLog(@"File Transfer Error: %@", [error localizedDescription]);

    // remove connection for activeTransfers
    [command.activeTransfers removeObjectForKey:objectId];
    [self.command.commandDelegate sendPluginResult:result callbackId:callbackId];
}

- (void)connection:(NSURLConnection*)connection didReceiveData:(NSData*)data
{
    self.bytesTransfered += data.length;
    [self.responseData appendData:data];

    if (self.direction == CDV_TRANSFER_DOWNLOAD) {
        BOOL lengthComputable = (self.bytesExpected != NSURLResponseUnknownLength);
        NSMutableDictionary* downloadProgress = [NSMutableDictionary dictionaryWithCapacity:3];
        [downloadProgress setObject:[NSNumber numberWithBool:lengthComputable] forKey:@"lengthComputable"];
        [downloadProgress setObject:[NSNumber numberWithInt:self.bytesTransfered] forKey:@"loaded"];
        [downloadProgress setObject:[NSNumber numberWithInt:self.bytesExpected] forKey:@"total"];
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:downloadProgress];
        [result setKeepCallbackAsBool:true];
        [self.command.commandDelegate sendPluginResult:result callbackId:callbackId];
    }
}

- (void)connection:(NSURLConnection*)connection didSendBodyData:(NSInteger)bytesWritten totalBytesWritten:(NSInteger)totalBytesWritten totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite
{
    if (self.direction == CDV_TRANSFER_UPLOAD) {
        NSMutableDictionary* uploadProgress = [NSMutableDictionary dictionaryWithCapacity:3];

        [uploadProgress setObject:[NSNumber numberWithBool:true] forKey:@"lengthComputable"];
        [uploadProgress setObject:[NSNumber numberWithInt:totalBytesWritten] forKey:@"loaded"];
        [uploadProgress setObject:[NSNumber numberWithInt:totalBytesExpectedToWrite] forKey:@"total"];
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:uploadProgress];
        [result setKeepCallbackAsBool:true];
        [self.command.commandDelegate sendPluginResult:result callbackId:callbackId];
    }
    self.bytesTransfered = totalBytesWritten;
}

// for self signed certificates
- (void)connection:(NSURLConnection*)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge*)challenge
{
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        if (self.trustAllHosts) {
            NSURLCredential* credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
            [challenge.sender useCredential:credential forAuthenticationChallenge:challenge];
        }
        [challenge.sender continueWithoutCredentialForAuthenticationChallenge:challenge];
    } else {
        [challenge.sender performDefaultHandlingForAuthenticationChallenge:challenge];
    }
}

- (id)init
{
    if ((self = [super init])) {
        self.responseData = [NSMutableData data];
    }
    return self;
}

@end;
