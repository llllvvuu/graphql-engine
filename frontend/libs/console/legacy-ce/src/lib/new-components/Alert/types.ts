// see: https://stackoverflow.com/questions/57103834/typescript-omit-a-property-from-all-interfaces-in-a-union-but-keep-the-union-s
// TS docs: https://www.typescriptlang.org/docs/handbook/2/conditional-types.html#distributive-conditional-types
type DistributiveOmit<T, K extends PropertyKey> = T extends any
  ? Omit<T, K>
  : never;

export type AlertMode = 'alert' | 'confirm' | 'prompt';

export type onCloseAsyncPromiseReturn = DismissAlertParams | void;

export type CommonAlertBase<Mode extends AlertMode> = {
  title: string;
  message: React.ReactNode;
  mode: Mode;
  confirmText?: string;
};

export type ConfirmableBase = {
  cancelText?: string;
  destructive?: boolean;
};

/**
 *
 * For all alert modes types, onClose/onCloseAsync are added with an XOR (exclusive or) -- that is, only one or the other can be present on the type
 *
 */

export type AlertParams = CommonAlertBase<'alert'> &
  (
    | { onClose?: () => void; onCloseAsync?: never }
    | {
        onClose?: never;
        onCloseAsync?: () => Promise<onCloseAsyncPromiseReturn>;
      }
  );

export type ConfirmParams = CommonAlertBase<'confirm'> &
  ConfirmableBase &
  (
    | { onClose: (args: onCloseProps) => void; onCloseAsync?: never }
    | {
        onClose?: never;
        onCloseAsync: (
          args: onCloseProps
        ) => Promise<onCloseAsyncPromiseReturn>;
      }
  );

export type PromptParams = CommonAlertBase<'prompt'> &
  ConfirmableBase & {
    promptLabel?: React.ReactNode;
    promptPlaceholder?: string;
    sanitizeGraphQL?: boolean;
  } & (
    | { onClose: (args: onClosePromptProps) => void; onCloseAsync?: never }
    | {
        onClose?: never;
        onCloseAsync: (
          args: onClosePromptProps
        ) => Promise<onCloseAsyncPromiseReturn>;
      }
  );

export type Params<Mode extends AlertMode> = DistributiveOmit<
  Extract<AlertParams | ConfirmParams | PromptParams, { mode: Mode }>,
  'mode'
>;

// alert/confirm
export type onCloseProps = { confirmed: boolean };

// prompt:
export type onClosePromptProps =
  | {
      confirmed: true;
      promptValue: string;
    }
  | {
      confirmed: false;
    };

export type DismissAlertParams = {
  withSuccess?: boolean;
  successText?: string;
  successDelay?: number;
};
