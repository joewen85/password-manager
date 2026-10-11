import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('PasswordManager EntryAbility onCreate');
  }

  onDestroy(): void {
    console.info('PasswordManager EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        console.error(`Failed to load the content. Code: ${err.code}, message: ${err.message}`);
        return;
      }
      console.info('Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    console.info('PasswordManager window stage onDestroy');
  }

  onForeground(): void {
    console.info('PasswordManager EntryAbility onForeground');
  }

  onBackground(): void {
    console.info('PasswordManager EntryAbility onBackground');
  }
}
