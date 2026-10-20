#ifndef AllKeyCore_h
#define AllKeyCore_h

char *AllKeyCreateKeys(char *requestJSON);
char *AllKeyCreateMnemonic(char *requestJSON);
char *AllKeyCreateMnemonicPage(char *requestJSON);
char *AllKeyInspectMnemonic(char *requestJSON);
char *AllKeyCreateElectrum(char *requestJSON);
char *AllKeyCalculate(char *requestJSON);
void AllKeyFree(char *pointer);

#endif
