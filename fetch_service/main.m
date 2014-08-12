//
//  main.m
//  fetch_service
//
//  Created by Axis on 8/12/14.
//  Copyright (c) 2014 Axis. All rights reserved.
//

#include <xpc/xpc.h>
#include <Foundation/Foundation.h>
#include <curl/curl.h>
#include <string.h>

typedef struct
{
    xpc_connection_t connection;
    int stop_download;
}fetch_progress_ctx_t;

size_t fetch_write_callback(char *ptr, size_t size, size_t nmemb, void *userdata)
{
    return fwrite(ptr, size, nmemb, userdata);
}

int fetch_progress_callback(void *ctx,
                            double dltotal,
                            double dlnow,
                            double ultotal,
                            double ulnow)
{
    fetch_progress_ctx_t *data = (fetch_progress_ctx_t*)ctx;
    if(data->stop_download)
        return true;
    
    if (dltotal!=0.0) {
        xpc_object_t message=xpc_dictionary_create(NULL, NULL, 0);
        if(message!=NULL) return true;
        xpc_dictionary_set_double(message, "progressValue", dlnow*100.0/dltotal);
        xpc_connection_send_message(data->connection, message);
        xpc_release(message);
    }
    
    return 0;
}


static int fetch_download_file(const char *url, int fd, fetch_progress_ctx_t *ctx, const char **errmsg)
{
    FILE* fp=NULL;
    CURL *curl=NULL;
    CURLcode err=CURLE_OK;
    
    if (errmsg) {
        errmsg=NULL;
    }
    
    if((fp=fdopen(dup(fd), "r+"))==NULL)
    {
        err=CURLE_WRITE_ERROR;
        goto error;
    }
    
    if((curl=curl_easy_init())==NULL)
    {
        err=CURLE_FAILED_INIT;
        goto error;
    }
    
    if((err=curl_easy_setopt(curl, CURLOPT_URL, url))!=CURLE_OK)
        goto error;
    if((err=curl_easy_setopt(curl, CURLOPT_WRITEDATA, fp))!=CURLE_OK)
        goto error;
    if((err=curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, fetch_write_callback))!=CURLE_OK)
        goto error;
    if((err=curl_easy_setopt(curl, CURLOPT_PROGRESSDATA, ctx))!=CURLE_OK)
        goto error;
    if((err=curl_easy_setopt(curl, CURLOPT_PROGRESSFUNCTION, fetch_progress_callback))!=CURLE_OK)
        goto error;
    if((err=curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L))!=CURLE_OK)//==>需要有进度表
        goto error;
    
    err=curl_easy_perform(curl);
    if(err==CURLE_ABORTED_BY_CALLBACK)
    {
        if (errmsg)
        {
            *errmsg="Download canceled";
        }
    }
        
    
error:
    if (fp!=NULL) {
        fclose(fp);
    }
    if (curl) {
        curl_easy_cleanup(curl);
    }
    
    return err;
}

//我们的请求中应该包含一个url的const string for downloading the file
static void fetch_process_request(xpc_object_t request, xpc_object_t reply)
{
    const char* url=xpc_dictionary_get_string(request, "url");
    /*
     ***Parameters
     [xdict]
     The dictionary object which is to be examined.
     [key]
     The key whose value is to be obtained.
     ***Return Value
     A new connection created from the value for the specified key. You are responsible for calling xpc_release() on the returned connection. NULL if the value for the specified key is not an endpoint containing a connection or if there is no value for the specified key. Each call to this method for the same key in the same dictionary will yield a different connection. See xpc_connection_create_from_endpoint() for discussion as to the responsibilities when dealing with the returned connection.
     */
    xpc_connection_t conn=xpc_dictionary_create_connection(request, "connection");
    int errorno=0;
    const char* errmsg=0;
    char *tempname=0;
    int ret_rd=-1;
    __block fetch_progress_ctx_t ctx={conn, FALSE};
    
    if(url==NULL || strncasecmp(url, "http://", 7)!=0)
    {
        printf("url dose not support http protocol\n");
        errorno=EINVAL;
        errmsg="url dose not support http protocol\n";
        goto error;
    }
    
    if(conn)
    {
        printf("url dose not have key named connection");
        errorno=EINVAL;
        errmsg="url dose not have key named connection";
        goto error;
    }
    
    //创建异常处理方式
    xpc_connection_set_event_handler(conn, ^(xpc_object_t event){
        xpc_type_t type=xpc_get_type(event);
        
        if(XPC_TYPE_ERROR==type && XPC_ERROR_CONNECTION_INTERRUPTED==type)
        {
            ctx.stop_download=TRUE;
        }
    });
    xpc_connection_resume(conn);
    
    if(sprintf(tempname, "%sfetch.XXXXXXX", getenv("TMPDIR"))<0)
    {
        errorno=errno;
        errmsg="can not alloc temp file name!";
        goto error;
    }
    
    if((ret_rd=mkstemp(tempname))<0)
    {
        free(tempname);
        errorno=errno;
        errmsg="can not alloc any temp file.";
        goto error;
    }
    
    unlink(tempname);
    free(tempname);
    
    //download the file
    fetch_download_file(url, ret_rd, &ctx, &errmsg);
    
error:
    if(conn!=NULL)
    {
        xpc_connection_suspend(conn);
    }
    
    if(errorno)
    {
        xpc_dictionary_set_int64(reply, "errorno", (int64_t)errorno);
    }
    if (errmsg) {
        xpc_dictionary_set_string(reply, "errmsg", errmsg);
    }
}

static void fetch_service_peer_event_handler(xpc_connection_t peer, xpc_object_t event)
{
	xpc_type_t type = xpc_get_type(event);
	if (type == XPC_TYPE_ERROR) {
		if (event == XPC_ERROR_CONNECTION_INVALID) {
			// The client process on the other end of the connection has either
			// crashed or cancelled the connection. After receiving this error,
			// the connection is in an invalid state, and you do not need to
			// call xpc_connection_cancel(). Just tear down any associated state
			// here.
            printf("error");
            xpc_connection_cancel(peer);
		} else if (event == XPC_ERROR_TERMINATION_IMMINENT) {
			// Handle per-connection termination cleanup.
		}
	} else {
		assert(type == XPC_TYPE_DICTIONARY);
        
        xpc_object_t requestMessage=event;
        /*
         * xpc_copy_description:
         * funtion: Copies a debug string describing the object.
         * Parameters
         * object
         * The object which is to be examined.
         * Return Value
         * A string describing object which contains information useful for debugging. This string should be disposed of with free(3) when done.
         */
        char *messageDescription=xpc_copy_description(requestMessage);
        printf("requestMessage debug message: %s\n", messageDescription);
        free(messageDescription);
        
        /*
         [Parameters]
         The original dictionary that is to be replied to.
         [Return Value]
         The new dictionary object. NULL if the dictionary did not come from the wire with a reply context.
         */
        xpc_object_t replyMessage = xpc_dictionary_create_reply(requestMessage);
        if (replyMessage==NULL) return ;
        
        //handle the replyMessage
        //todo: fetch_process_request
        fetch_process_request(requestMessage, replyMessage);    //得到对应的返回值
        
        //print the debug message of reply description
        messageDescription=xpc_copy_description(replyMessage);
        printf("replyMessage debug message : %s\n", messageDescription);
        free(messageDescription);
        
        xpc_connection_send_message(peer, replyMessage);
        xpc_release(replyMessage);
	}
}

static void fetch_service_event_handler(xpc_connection_t peer) 
{
    char *queue_name=NULL;
    //Get the queue's name
    sprintf(queue_name, "com.apple.sandboxfetch.");
    //create the dispatch_queue to do the sync work.
    dispatch_queue_t peer_event_queue=dispatch_queue_create(queue_name, DISPATCH_QUEUE_SERIAL);
    if(peer_event_queue==NULL)
        return;
    free(queue_name);
    xpc_connection_set_target_queue(peer, peer_event_queue);
    
	//set the handler queue for connection
	xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
		fetch_service_peer_event_handler(peer, event);
	});
	
    //enbale the peer connection to receive message.
	xpc_connection_resume(peer);
}

int main(int argc, const char *argv[])
{
	xpc_main(fetch_service_event_handler);
	return 0;
}
