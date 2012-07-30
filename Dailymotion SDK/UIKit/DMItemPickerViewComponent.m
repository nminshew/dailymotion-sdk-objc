//
//  DMPickerViewComponent.m
//  Dailymotion SDK iOS
//
//  Created by Olivier Poitrey on 25/07/12.
//
//

#import "DMItemPickerViewComponent.h"
#import "DMItemPickerLabel.h"
#import "DMSubscriptingSupport.h"
#import "objc/runtime.h"

static char operationKey;

@interface DMItemPickerViewComponent ()

@property (nonatomic, strong) DMItemCollection *_itemCollection;
@property (nonatomic, strong) UIView<DMItemDataSourceItem> *(^_createRowViewBlock)();
@property (nonatomic, assign) BOOL _loaded;
@property (nonatomic, strong) NSMutableArray *_operations;

@end

@implementation DMItemPickerViewComponent

- (id)initWithItemCollection:(DMItemCollection *)itemCollection createRowViewBlock:(UIView<DMItemDataSourceItem> *(^)())createRowViewBlock
{
    NSParameterAssert(itemCollection != nil);
    NSParameterAssert(createRowViewBlock != nil);

    if ((self = [super init]))
    {
        __itemCollection = itemCollection;
        __createRowViewBlock = createRowViewBlock;
        [self addObserver:self forKeyPath:@"itemCollection.currentEstimatedTotalItemsCount" options:0 context:NULL];
        [self addObserver:self forKeyPath:@"itemCollection.api.currentReachabilityStatus" options:NSKeyValueObservingOptionOld context:NULL];
    }
    return self;
}

- (id)initWithItemCollection:(DMItemCollection *)itemCollection withTitleFromField:(NSString *)fieldName
{
    return [self initWithItemCollection:itemCollection createRowViewBlock:^
    {
        return [[DMItemPickerLabel alloc] initWithFieldName:fieldName];
    }];
}

- (void)dealloc
{
    [self cancelAllOperations];
    [self removeObserver:self forKeyPath:@"itemCollection.currentEstimatedTotalItemsCount"];
    [self removeObserver:self forKeyPath:@"itemCollection.api.currentReachabilityStatus"];
}

- (void)cancelAllOperations
{
    [self._operations makeObjectsPerformSelector:@selector(cancel)];
    [self._operations removeAllObjects];
}

- (NSInteger)numberOfRows
{
    if (!self._loaded)
    {
        UIView<DMItemDataSourceItem> *view = self._createRowViewBlock();

        __weak DMItemPickerViewComponent *bself = self;
        DMItemOperation *operation = [self._itemCollection withItemFields:view.fieldsNeeded atIndex:0 do:^(NSDictionary *data, BOOL stalled, NSError *error)
        {
            if (error)
            {
                bself.lastError = error;
                bself._loaded = NO;
                if ([bself.delegate respondsToSelector:@selector(pickerViewComponent:didFailWithError:)])
                {
                    [bself.delegate pickerViewComponent:bself didFailWithError:error];
                }
            }
        }];
        self._operations = NSMutableArray.array;
        if (!operation.isFinished) // The operation can be synchrone in case the itemCollection was already loaded or restored from disk
        {
            [self._operations addObject:operation];
            [operation addObserver:self forKeyPath:@"isFinished" options:0 context:NULL];

            // Only notify about loading if we have something to load on the network
            if ([self.delegate respondsToSelector:@selector(pickerViewComponentDidUpdateContent:)])
            {
                [self.delegate pickerViewComponentDidUpdateContent:self];
            }
        }
        
        self._loaded = YES;
    }
    return self._itemCollection.currentEstimatedTotalItemsCount;
}

- (UIView *)viewForRow:(NSInteger)row reusingView:(UIView<DMItemDataSourceItem> *)view
{
    if (!view)
    {
        view = self._createRowViewBlock();
    }

    DMItemOperation *previousOperation = objc_getAssociatedObject(view, &operationKey);
    [previousOperation cancel];

    [view prepareForLoading];

    __weak DMItemPickerViewComponent *bself = self;
    DMItemOperation *operation = [self._itemCollection withItemFields:view.fieldsNeeded atIndex:row do:^(NSDictionary *data, BOOL stalled, NSError *error)
    {
        objc_setAssociatedObject(view, &operationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (error)
        {
            BOOL notify = !bself.lastError; // prevents from error storms
            bself.lastError = error;
            if (notify)
            {
                if ([bself.delegate respondsToSelector:@selector(pickerViewComponent:didFailWithError:)])
                {
                    [bself.delegate pickerViewComponent:bself didFailWithError:error];
                }
            }
        }
        else
        {
            bself.lastError = nil;
            [view setFieldsData:data];
        }
    }];
    
    if (!operation.isFinished)
    {
        [self._operations addObject:operation];
        [operation addObserver:self forKeyPath:@"isFinished" options:0 context:NULL];
        objc_setAssociatedObject(view, &operationKey, operation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    return view;
}

- (void)didSelectRow:(NSInteger)row
{
    __weak DMItemPickerViewComponent *bself = self;
    [self._itemCollection withItemFields:@[@"id"] atIndex:row do:^(NSDictionary *data, BOOL stalled, NSError *error)
    {
        if (error)
        {
            BOOL notify = !bself.lastError; // prevents from error storms
            bself.lastError = error;
            if (notify)
            {
                if ([bself.delegate respondsToSelector:@selector(pickerViewComponent:didFailWithError:)])
                {
                    [bself.delegate pickerViewComponent:bself didFailWithError:error];
                }
            }
        }
        else
        {
            if ([bself.delegate respondsToSelector:@selector(pickerViewComponent:didSelectItem:)])
            {
                // TODO share the cache of the collection item
                [bself.delegate pickerViewComponent:bself didSelectItem:[DMItem itemWithType:bself._itemCollection.type forId:data[@"id"] fromAPI:self._itemCollection.api]];
            }
        }
    }];
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@"itemCollection.currentEstimatedTotalItemsCount"] && object == self)
    {
        if (!self._loaded) return;
        if ([self.delegate respondsToSelector:@selector(pickerViewComponentDidUpdateContent:)])
        {
            [self.delegate pickerViewComponentDidUpdateContent:self];
        }
    }
    else if ([keyPath isEqualToString:@"itemCollection.api.currentReachabilityStatus"] && object == self)
    {
        if (!self._loaded) return;
        DMNetworkStatus previousRechabilityStatus = ((NSNumber *)change[NSKeyValueChangeOldKey]).intValue;
        if (self._itemCollection.api.currentReachabilityStatus != DMNotReachable && previousRechabilityStatus == DMNotReachable)
        {
            // Became recheable: notify table view controller that it should reload table data
            if ([self.delegate respondsToSelector:@selector(pickerViewComponentDidLeaveOfflineMode:)])
            {
                [self.delegate pickerViewComponentDidLeaveOfflineMode:self];
            }
        }
        else if (self._itemCollection.api.currentReachabilityStatus == DMNotReachable && previousRechabilityStatus != DMNotReachable)
        {
            if ([self.delegate respondsToSelector:@selector(pickerViewComponentDidEnterOfflineMode:)])
            {
                [self.delegate pickerViewComponentDidEnterOfflineMode:self];
            }
        }
    }
    else if ([keyPath isEqualToString:@"isFinished"] && [object isKindOfClass:DMItemOperation.class])
    {
        if (((DMItemOperation *)object).isFinished)
        {
            [self._operations removeObject:object];
            [object removeObserver:self forKeyPath:@"isFinished"];
        }
    }
    else
    {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

@end