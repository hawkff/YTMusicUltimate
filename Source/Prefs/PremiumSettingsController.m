#import "PremiumSettingsController.h"

@implementation PremiumSettingsController

// Single source of truth for rows, cells, and toggle handling so they can't drift apart.
- (NSArray<NSDictionary *> *)settingsData {
    return @[
        @{@"title": LOC(@"NO_ADS"), @"desc": LOC(@"NO_ADS_DESC"), @"key": @"noAds", @"default": @NO},
        @{@"title": LOC(@"BACKGROUND_PLAYBACK"), @"desc": LOC(@"BACKGROUND_PLAYBACK_DESC"), @"key": @"backgroundPlayback", @"default": @NO},
        @{@"title": LOC(@"MOBILE_AUDIO_TIER"), @"desc": LOC(@"MOBILE_AUDIO_TIER_DESC"), @"key": @"mobileAudioTierSpoof", @"default": @YES}
    ];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = LOC(@"PREMIUM_SETTINGS");
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.tableView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.tableView.widthAnchor constraintEqualToAnchor:self.view.widthAnchor],
        [self.tableView.heightAnchor constraintEqualToAnchor:self.view.heightAnchor]
    ]];
}

#pragma mark - Table view stuff
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath{
    return UITableViewAutomaticDimension;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self settingsData].count;
}

-(UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell1"];

    NSDictionary *YTMUltimateDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    NSDictionary *data = [self settingsData][indexPath.row];

    cell.textLabel.text = data[@"title"];
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.detailTextLabel.text = data[@"desc"];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    id storedValue = YTMUltimateDict[data[@"key"]];
    BOOL isOn = storedValue ? [storedValue boolValue] : [data[@"default"] boolValue];

    ABCSwitch *switchControl = [[NSClassFromString(@"ABCSwitch") alloc] init];
    switchControl.onTintColor = [UIColor colorWithRed:30.0/255.0 green:150.0/255.0 blue:245.0/255.0 alpha:1.0];
    [switchControl addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
    switchControl.tag = indexPath.row;
    switchControl.on = isOn;
    cell.accessoryView = switchControl;

    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (void)toggleSwitch:(UISwitch *)sender {
    NSArray<NSDictionary *> *settingsData = [self settingsData];
    if (sender.tag < 0 || sender.tag >= (NSInteger)settingsData.count) return;

    NSDictionary *data = settingsData[sender.tag];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *YTMUltimateDict = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"]];

    [YTMUltimateDict setObject:@([sender isOn]) forKey:data[@"key"]];
    [defaults setObject:YTMUltimateDict forKey:@"YTMUltimate"];
}

@end